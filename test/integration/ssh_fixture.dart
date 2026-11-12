import 'dart:async';
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
  Process? _agent;

  /// Why the tests can't run here, or null when they can.
  String? get skip => switch ((_port, _isCi)) {
        (null, _) => 'Needs the sshd CI starts (SSH_TEST_PORT)',
        (_, false) => "Logs in to CI's sshd, so runs only where CI=true",
        _ => null,
      };

  /// The sshd, with host keys checked against the fixture's known_hosts,
  /// which holds the sshd's key unless a test calls [forgetHostKey].
  SshTarget get target => SshTarget('127.0.0.1', port: _port);

  /// How ssh names [target] in known_hosts.
  String get hostKeyName => _hostKeyName;

  /// The sshd as the current user, for an ssh with no config at all.
  SshTarget get bareTarget => SshTarget(
        '127.0.0.1',
        port: _port,
        user: Platform.environment[Platform.isWindows ? 'USERNAME' : 'USER'],
      );

  /// Same server, but `StrictHostKeyChecking yes` in the config.
  SshTarget get strictTarget => const SshTarget('strict-host-keys');

  /// Same server, with only a key file that doesn't exist, so ssh can log in
  /// only through the agent at SSH_AUTH_SOCK.
  SshTarget get agentOnlyTarget => const SshTarget('agent-only');

  /// Like [agentOnlyTarget], but the config names the agent with
  /// `IdentityAgent`, as 1Password and others set up.
  SshTarget get identityAgentTarget => const SshTarget('identity-agent');

  /// Like [identityAgentTarget], but nothing listens on the agent's socket.
  SshTarget get deadAgentTarget => const SshTarget('dead-agent');

  /// Same server, reached through a ProxyCommand that runs `ssh -W` to it.
  SshTarget get proxyCommandTarget => const SshTarget('proxy-command');

  /// The pid of the `ssh -W` that [proxyCommandTarget]'s ProxyCommand runs,
  /// once it has started.
  Future<int> get proxyPid => eventually(() {
        if (!_proxyPid.existsSync()) return null;
        return int.tryParse(_proxyPid.readAsStringSync().trim());
      });

  /// The socket of the agent [startAgent] runs.
  String get agentSocket =>
      '${_require(_directory, 'setUpAll').path}/agent.sock';

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

  File get _proxyPid =>
      File('${_require(_directory, 'setUpAll').path}/proxy.pid');

  String get _hostKeyName => '[127.0.0.1]:$_port';

  /// Writes the config and the ssh that reads it, and waits for the sshd.
  Future<void> setUpAll() async {
    if (skip != null) return;

    final directory = Directory.systemTemp.createTempSync('system_ssh_test');
    _directory = directory;
    final knownHosts = _knownHosts.path.replaceAll(r'\', '/');
    String agentHost(String name, String? agent) => '''
Host $name
  HostName 127.0.0.1
  Port $_port
  IdentityFile ${directory.path}/no_such_key
${agent == null ? '' : '  IdentityAgent $agent\n'}  StrictHostKeyChecking accept-new
  UserKnownHostsFile $knownHosts
''';
    File('${directory.path}/config').writeAsStringSync('''
${agentHost('agent-only', null)}
${agentHost('identity-agent', '${directory.path}/agent.sock')}
${agentHost('dead-agent', '${directory.path}/dead.sock')}
Host proxy-command
  HostName 127.0.0.1
  Port $_port
  ProxyCommand ${ssh.replaceAll(r'\', '/')} -W %h:%p jump
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $knownHosts

Host jump
  HostName 127.0.0.1
  Port $_port
  BatchMode yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $knownHosts

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
      // ssh runs a ProxyCommand as `exec <command>`, so $$ ends up ssh -W's pid.
      File(ssh).writeAsStringSync('''
#!/bin/sh
case " \$* " in *" -W "*) echo \$\$ > '${_proxyPid.path}' ;; esac
exec ssh -F '${directory.path}/config' "\$@"
''');
      await Process.run('chmod', ['+x', ssh]);
    }

    for (var attempt = 1;; attempt++) {
      try {
        (await Socket.connect(InternetAddress.loopbackIPv4, _port!)).destroy();
        break;
      } on SocketException {
        if (attempt == 50) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    final scan = await Process.run(
      'ssh-keyscan',
      ['-p', '$_port', '127.0.0.1'],
    );
    final keys = '${scan.stdout}';
    if (keys.trim().isEmpty) throw StateError('ssh-keyscan: ${scan.stderr}');
    _scannedHostKeys = keys;
    await rememberHostKeyForBareTarget();
  }

  /// The sshd's keys, as ssh-keyscan read them once.
  String? _scannedHostKeys;

  /// The runner's own known_hosts, which ssh with no config checks.
  File get runnerKnownHosts => File(
        '${Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME']}'
        '/.ssh/known_hosts',
      );

  /// Adds the sshd's keys to [runnerKnownHosts] unless it has them.
  Future<void> rememberHostKeyForBareTarget() async {
    final found = await Process.run(
      'ssh-keygen',
      ['-F', _hostKeyName, '-f', runnerKnownHosts.path],
    );
    if (found.exitCode == 0) return;

    final file = runnerKnownHosts..parent.createSync(recursive: true);
    final existing = file.existsSync() ? file.readAsStringSync() : '';
    final separator = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
    file.writeAsStringSync(
      '$separator${_require(_scannedHostKeys, 'setUpAll')}',
      mode: FileMode.append,
    );
  }

  /// Removes the sshd's keys from [runnerKnownHosts].
  Future<void> forgetHostKeyForBareTarget() async {
    await Process.run(
      'ssh-keygen',
      ['-R', _hostKeyName, '-f', runnerKnownHosts.path],
    );
  }

  /// Empties the fixture's known_hosts, so [target]'s key is unknown.
  void forgetHostKey() {
    if (_knownHosts.existsSync()) _knownHosts.deleteSync();
  }

  /// Runs an ssh-agent on [agentSocket] holding the key the sshd trusts.
  Future<void> startAgent() async {
    final agent = await Process.start('ssh-agent', ['-D', '-a', agentSocket]);
    _agent = agent;
    unawaited(agent.stdout.drain<void>());
    unawaited(agent.stderr.drain<void>());
    for (var attempt = 1; !File(agentSocket).existsSync(); attempt++) {
      if (attempt == 50) throw StateError('ssh-agent did not start');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    final home = Platform.environment['HOME'];
    final added = await Process.run(
      'ssh-add',
      ['$home/.ssh/id_ed25519'],
      environment: {'SSH_AUTH_SOCK': agentSocket},
    );
    if (added.exitCode != 0) throw StateError('ssh-add: ${added.stderr}');
  }

  /// Stops the agent [startAgent] ran.
  Future<void> stopAgent() async {
    _agent?.kill();
    await _agent?.exitCode;
    _agent = null;
  }

  /// Deletes the config and the ssh that reads it.
  Future<void> tearDownAll() async {
    if (_directory case final directory?) deleteSoon(directory);
  }

  /// Fails a test that `--run-skipped` runs without the opt-in.
  Future<void> setUp() async {
    if (skip case final reason?) throw StateError(reason);

    _knownHosts.writeAsStringSync(_require(_scannedHostKeys, 'setUpAll'));
    if (_proxyPid.existsSync()) _proxyPid.deleteSync();

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

  /// What the fixture's known_hosts holds.
  Future<String> knownHostsText() => _knownHosts.readAsString();

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
