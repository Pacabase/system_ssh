import 'dart:convert';
import 'dart:io';

import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import '../fakes/fakes.dart';

/// An sshd on 127.0.0.1 that CI starts with `.github/actions/sshd`, an ssh
/// that reads the fixture's own config instead of `~/.ssh/config`, and an
/// echo server to tunnel to.
///
/// It logs in with the runner's `~/.ssh/id_ed25519`, which the sshd trusts,
/// so it runs only in CI with SSH_TEST_PORT set.
final class SshFixture {
  SshFixture()
      : _port = int.tryParse(Platform.environment['SSH_TEST_PORT'] ?? ''),
        _isCi = Platform.environment['CI'] == 'true';

  final int? _port;
  final bool _isCi;
  Directory? _directory;
  ServerSocket? _echo;
  final _accepted = <Socket>[];

  /// Why the tests can't run here, or null when they can.
  String? get skip => switch ((_port, _isCi)) {
        (null, _) => 'Needs the sshd CI starts (SSH_TEST_PORT)',
        (_, false) => "Logs in to CI's sshd, so runs only where CI=true",
        _ => null,
      };

  /// The sshd, with host keys checked against the fixture's known_hosts.
  SshTarget get target => SshTarget('127.0.0.1', port: _port);

  /// The sshd as the current user, for an ssh with no config at all.
  SshTarget get bareTarget => SshTarget(
        '127.0.0.1',
        port: _port,
        user: Platform.environment[Platform.isWindows ? 'USERNAME' : 'USER'],
      );

  /// Same server, but `StrictHostKeyChecking yes` in the config.
  SshTarget get strictTarget => const SshTarget('strict-host-keys');

  /// The ssh that reads the fixture's config, for `executable:`.
  String get ssh =>
      '${_require(_directory, 'setUpAll').path}${Platform.pathSeparator}'
      '${Platform.isWindows ? 'ssh_wrapper.exe' : 'ssh'}';

  /// The echo server's host, as the sshd sees it.
  String get echoHost => '127.0.0.1';

  /// The echo server's port.
  int get echoPort => _require(_echo, 'setUp').port;

  File get _knownHosts =>
      File('${_require(_directory, 'setUpAll').path}/known_hosts');

  String get _hostKeyName => '[127.0.0.1]:$_port';

  /// Writes the config and the ssh that reads it, and waits for the sshd.
  Future<void> setUpAll() async {
    if (skip != null) return;

    final directory = Directory.systemTemp.createTempSync('system_ssh_test');
    _directory = directory;
    final knownHosts = _knownHosts.path.replaceAll(r'\', '/');
    File('${directory.path}/config').writeAsStringSync('''
Host strict-host-keys
  HostName 127.0.0.1
  Port $_port
  StrictHostKeyChecking yes
  UserKnownHostsFile $knownHosts

Host 127.0.0.1
  UserKnownHostsFile $knownHosts
''');

    if (Platform.isWindows) {
      File(await compileExecutable('test/integration/ssh_wrapper_main.dart'))
          .copySync(ssh);
    } else {
      File(ssh).writeAsStringSync('''
#!/bin/sh
exec ssh -F '${directory.path}/config' "\$@"
''');
      await Process.run('chmod', ['+x', ssh]);
    }

    for (var attempt = 1;; attempt++) {
      try {
        (await Socket.connect(InternetAddress.loopbackIPv4, _port!)).destroy();
        return;
      } on SocketException {
        if (attempt == 50) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// Deletes the config and the ssh that reads it.
  Future<void> tearDownAll() async {
    if (_directory case final directory?) deleteSoon(directory);
  }

  /// Fails a test that `--run-skipped` runs without the opt-in.
  Future<void> setUp() async {
    if (skip case final reason?) throw StateError(reason);

    if (_knownHosts.existsSync()) _knownHosts.deleteSync();

    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _echo = echo;
    echo.listen((socket) {
      _accepted.add(socket);
      socket.listen(
        socket.add,
        onDone: socket.close,
        onError: (_) => socket.destroy(),
      );
    });
  }

  /// Closes the echo server and what connected to it.
  Future<void> tearDown() async {
    for (final socket in _accepted) {
      socket.destroy();
    }
    _accepted.clear();
    await _echo?.close();
    _echo = null;
  }

  /// Whether the fixture's known_hosts has the sshd's key.
  Future<bool> isKnownHost() async {
    final result = await Process.run('ssh-keygen', [
      '-F',
      _hostKeyName,
      '-f',
      _knownHosts.path,
    ]);

    return result.exitCode == 0;
  }

  /// Writes a key for the test host that isn't the server's.
  Future<void> rememberWrongHostKey() async {
    final key = '${_require(_directory, 'setUpAll').path}/wrong_key';
    await Process.run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      key,
    ]);
    final publicKey = File('$key.pub').readAsStringSync().trim();

    _knownHosts.writeAsStringSync('$_hostKeyName $publicKey\n');
  }

  /// What comes back through [port] for [message], or less if it closes or resets.
  Future<String> echoThrough(int port, String message) async {
    final bytes = <int>[];

    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      addTearDown(socket.destroy);
      socket.done.ignore();
      socket.add(utf8.encode(message));
      await socket
          .expand((chunk) => chunk)
          .take(message.length)
          .forEach(bytes.add)
          .timeout(const Duration(seconds: 5));
    } on SocketException {
      // ssh resets the local side when the endpoint refuses.
    }

    return utf8.decode(bytes);
  }

  static T _require<T extends Object>(T? value, String step) =>
      value ?? (throw StateError('SshFixture.$step did not run'));
}
