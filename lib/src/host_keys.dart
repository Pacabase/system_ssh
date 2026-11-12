import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'exceptions.dart';
import 'logger.dart';
import 'processes.dart';
import 'ssh_command.dart';
import 'ssh_host_key.dart';
import 'ssh_output.dart';
import 'ssh_target.dart';

final _serverHostKey = RegExp(r'^debug\d: Server host key: \S+ (\S+)');
final _unknown = RegExp(
  r'^No (\S+) host key is known for (.+) and you have requested strict checking\.',
);
final _changedHost = RegExp(
  r'[Hh]ost key for (.+) has changed and you have requested strict checking',
);
final _changedType =
    RegExp(r'^The fingerprint for the (\S+) key sent by the remote host is');
final _known = RegExp(r"^debug\d: Host '(.+)' is known and matches the ");

/// Whether `ssh -G` [config] leaves `StrictHostKeyChecking` at `ask`, where
/// the tunnel checks strictly and an unknown key is the caller's to trust.
bool asksAboutHostKeys(Map<String, String> config) =>
    config.isEmpty || config['stricthostkeychecking'] == 'ask';

/// How ssh names the host in `known_hosts` and in its messages, or null when
/// [config] couldn't be read.
String? knownHostsName(Map<String, String> config) {
  if (config['hostkeyalias'] case final alias?) return alias.toLowerCase();
  final host = config['hostname']?.toLowerCase();
  if (host == null) return null;

  final port = config['port'] ?? '22';
  return port == '22' ? host : '[$host]:$port';
}

/// [exception] as an [SshHostKeyChangedException] or, when [config] asks
/// about host keys, an [SshUnknownHostKeyException], or null when it is
/// neither.
SshTunnelException? hostKeyFailure(
  SshTunnelException exception,
  Map<String, String> config,
) {
  final log = exception.log;
  if (!_failedOnHostKey(log, config)) return null;
  final expected = knownHostsName(config);

  if (changedHostKey(log) case final hostKey?
      when expected == null || hostKey.host.toLowerCase() == expected) {
    return SshHostKeyChangedException(
      hostKey,
      log: log,
      exitCode: exception.exitCode,
    );
  }

  if (!asksAboutHostKeys(config)) return null;
  // The last match: a ProxyJump host's banner, printed before, can say anything.
  for (final (index, line) in log.indexed.toList().reversed) {
    final match = _unknown.firstMatch(line);
    if (match == null) continue;

    final host = match[2]!;
    // A ProxyJump host's own ssh gets none of our options: not ours to ask about.
    if (expected != null && host.toLowerCase() != expected) continue;

    final fingerprint = _lastFingerprint(log.take(index));
    if (fingerprint == null) return null;

    return SshUnknownHostKeyException(
      SshHostKey(host: host, type: match[1]!, fingerprint: fingerprint),
      log: log,
      exitCode: exception.exitCode,
    );
  }
  return null;
}

/// Whether [log] is ssh giving up on a host key, rather than a server's
/// banner printing the words: ssh says so, and never logged in to the host.
bool _failedOnHostKey(List<String> log, Map<String, String> config) {
  if (!log.any((line) => line.startsWith('Host key verification failed'))) {
    return false;
  }
  final host = config['hostname'];
  return host == null ||
      !log.any((line) => line.startsWith('Authenticated to $host '));
}

/// The key ssh says replaced the one in `known_hosts`, or null when it says
/// none did.
SshHostKey? changedHostKey(List<String> log) {
  final host = log.map(_changedHost.firstMatch).nonNulls.firstOrNull?[1];
  if (host == null) return null;

  final typeLine = log.indexWhere(_changedType.hasMatch);
  if (typeLine < 0 || typeLine + 1 >= log.length) return null;

  final type = _changedType.firstMatch(log[typeLine])![1]!;
  final fingerprint = log[typeLine + 1].trim().replaceFirst(RegExp(r'\.$'), '');
  return SshHostKey(host: host, type: type, fingerprint: fingerprint);
}

String? _lastFingerprint(Iterable<String> log) =>
    log.map(_serverHostKey.firstMatch).nonNulls.lastOrNull?[1];

/// The key in a `known_hosts` [entry] as ssh shows it, fingerprinted with
/// the hash [like]'s fingerprint uses, or null when [entry] isn't one.
SshHostKey? knownHostsKey(
  String entry, {
  required String host,
  required SshHostKey like,
}) {
  final fields = entry.trim().split(RegExp(r'\s+'));
  if (fields.length < 3 || fields.first.startsWith('@')) return null;
  try {
    final blob = base64.decode(fields[2]);
    return SshHostKey(
      host: host,
      type: keyTypeName(fields[1]),
      fingerprint: fingerprintOf(blob, like: like.fingerprint),
    );
  } on FormatException {
    return null;
  }
}

/// [blob]'s fingerprint as ssh prints it: MD5 when [like] is one, as under
/// `FingerprintHash md5`, otherwise SHA256.
String fingerprintOf(List<int> blob, {String like = 'SHA256:'}) {
  if (like.startsWith('MD5:')) {
    final hex = md5
        .convert(blob)
        .bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'));
    return 'MD5:${hex.join(':')}';
  }
  final digest = base64.encode(sha256.convert(blob).bytes);
  return 'SHA256:${digest.replaceAll('=', '')}';
}

/// The name ssh's messages give a key type, such as `ED25519` for
/// `ssh-ed25519`.
String keyTypeName(String type) => switch (type) {
      'ssh-ed25519' => 'ED25519',
      'ssh-rsa' => 'RSA',
      'ssh-dss' => 'DSA',
      'sk-ssh-ed25519@openssh.com' => 'ED25519-SK',
      'sk-ecdsa-sha2-nistp256@openssh.com' => 'ECDSA-SK',
      _ when type.startsWith('ecdsa-sha2-') => 'ECDSA',
      _ => type,
    };

/// [open]'s result, with a host key failure thrown as its own exception.
Future<T> checkingHostKeys<T>(
  Map<String, String> config,
  Future<T> Function() open,
) async {
  try {
    return await open();
  } on SshTunnelException catch (exception) {
    if (hostKeyFailure(exception, config) case final failure?) throw failure;
    rethrow;
  }
}

/// The ssh that checks [server]'s key against the user's known hosts and,
/// as `accept-new` does, writes a new one to [knownHosts] rather than to
/// theirs, then gives up without logging in.
List<String> hostKeyCommand(
  SshTarget server, {
  required String knownHosts,
  Map<String, String> config = const {},
  String executable = 'ssh',
}) =>
    [
      executable,
      '-nNTv',
      ...['-o', 'BatchMode=yes'],
      ...['-o', 'StrictHostKeyChecking=accept-new'],
      ...[
        '-o',
        'UserKnownHostsFile=${[
          knownHosts,
          ...userKnownHostsFiles(config),
        ].map((file) => '"${file.replaceAll(r'\', '/')}"').join(' ')}',
      ],
      ...['-o', 'PreferredAuthentications=none'],
      ...['-o', 'ClearAllForwardings=yes'],
      ...['-o', 'PermitLocalCommand=no'],
      ...['-o', 'ControlPath=none'],
      if (config['forkafterauthentication'] == 'yes') ...[
        '-o',
        'ForkAfterAuthentication=no',
      ],
      if (config.isEmpty || config['connecttimeout'] == 'none') ...[
        '-o',
        'ConnectTimeout=15',
      ],
      ...destinationArguments(server),
    ];

/// `SystemSshClient.trustHostKey`, with the parts tests replace.
Future<void> trustSystemHostKey(
  SshTarget server,
  SshHostKey hostKey, {
  required String executable,
  required Map<String, String> config,
  Map<String, String> environment = const {},
  Future<void>? abortTrigger,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final target = userKnownHostsFile(config, environment: environment);
  final directory = Directory.systemTemp.createTempSync('system_ssh_host_key');
  try {
    final read = File('${directory.path}/known_hosts')..createSync();
    final command = hostKeyCommand(
      server,
      knownHosts: read.path,
      config: config,
      executable: executable,
    );
    logger.info(command.join(' '));

    final (log, code) = await _run(
      command,
      environment: environment,
      timeout: timeout,
      abortTrigger: abortTrigger,
      host: config['hostname'],
    );

    final entries =
        read.readAsLinesSync().where((line) => line.trim().isNotEmpty).toList();
    if (entries.isEmpty) {
      if (code == 127) throw SshNotFoundException();
      // ssh wrote no new key, so no server got far enough to print a banner:
      // its log is ssh's own.
      if (changedHostKey(log) case final changed?) {
        throw SshHostKeyChangedException(changed, log: log, exitCode: code);
      }
      final name = knownHostsName(config);
      if (log.any(
        (line) => switch (_known.firstMatch(line)) {
          final match? => name == null || match[1]!.toLowerCase() == name,
          null => false,
        },
      )) {
        return;
      }
      throw tunnelFailure(log, code);
    }

    // The key ssh wrote, not the one its log names: a server's banner, printed
    // after the key exchange, can print any line.
    final offered = entries
        .map((entry) => knownHostsKey(entry, host: hostKey.host, like: hostKey))
        .toSet();
    final key = offered.length == 1 ? offered.single : null;
    if (key == null) {
      throw SshException("couldn't read the host key ssh got: $entries");
    }
    if (key.fingerprint != hostKey.fingerprint) {
      throw SshUnknownHostKeyException(key, log: log, exitCode: code);
    }

    _append(target, entries);
    logger.info('Added ${hostKey.host} ${hostKey.type} to ${target.path}');
  } finally {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // A Windows ssh still exiting can hold the file a moment longer.
    }
  }
}

Future<(List<String>, int)> _run(
  List<String> command, {
  required Map<String, String> environment,
  required Duration timeout,
  Future<void>? abortTrigger,
  String? host,
}) async {
  final aborted = Completer<void>();
  unawaited(abortTrigger?.then((_) => aborted.complete(), onError: (_) {}));

  final process = await startWatched(command, environment: environment);
  unawaited(process.stdout.drain<void>());
  final lines = <String>[];
  final stderrDone = Completer<void>();
  process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen(
    (line) {
      logger.fine(line);
      lines.add(line);
      // A server that lets the `none` method in has nothing more to show. A
      // ProxyJump host's ssh logs in to the jump host first, under its name.
      if (host != null && line.startsWith('Authenticated to $host ')) {
        process.kill();
      }
    },
    onError: (Object _) {},
    onDone: stderrDone.complete,
  );

  try {
    final code = await Future.any([
      process.exitCode,
      aborted.future.then((_) => throw const SshTunnelAbortedException()),
    ]).timeout(timeout);
    // ssh's last lines can land after its exit code; a ProxyCommand that
    // outlives it can hold stderr open longer.
    await stderrDone.future
        .timeout(const Duration(seconds: 1), onTimeout: () {});
    return (List<String>.unmodifiable(lines), code);
  } on TimeoutException {
    process.kill();
    throw const SshTunnelException("ssh didn't read the host key in time");
  } on SshTunnelAbortedException {
    process.kill();
    rethrow;
  }
}

/// The user's `UserKnownHostsFile`s, as `ssh -G` prints them.
List<String> userKnownHostsFiles(Map<String, String> config) =>
    switch (config['userknownhostsfile']) {
      // ssh -G prints them space-separated without quotes, so a space only
      // ends a path where the next one starts.
      final files? => files.split(RegExp(r' (?=[~/%]|[A-Za-z]:[\\/])')),
      null => const ['~/.ssh/known_hosts', '~/.ssh/known_hosts2'],
    };

/// The user's home, as ssh takes `~`: on Windows the profile, whatever
/// `HOME` a shell set.
String homeDirectory(Map<String, String> environment) {
  final names =
      Platform.isWindows ? ['USERPROFILE', 'HOME'] : ['HOME', 'USERPROFILE'];
  // Variables the app sets for ssh come before the process's own.
  return ([environment, Platform.environment]
              .expand((variables) => names.map((name) => variables[name]))
              .nonNulls
              .firstOrNull ??
          '')
      .replaceAll(r'\', '/');
}

/// The file ssh adds new host keys to: the first `UserKnownHostsFile`.
File userKnownHostsFile(
  Map<String, String> config, {
  Map<String, String> environment = const {},
}) {
  final home = homeDirectory(environment);
  final first = userKnownHostsFiles(config).first;
  if (first == 'none') {
    throw const SshConfigException(
      'UserKnownHostsFile is none, so there is no file to add the key to',
    );
  }

  final user = environment['USER'] ??
      Platform.environment['USER'] ??
      Platform.environment['USERNAME'] ??
      '';
  final path = first
      .replaceFirst(RegExp(r'^~(?=[\\/]|$)'), home)
      .replaceAllMapped(RegExp('%(.)'), (match) {
    return switch (match[1]) {
      '%' => '%',
      'd' => home,
      'u' => user,
      _ => throw SshConfigException(
          "can't tell which file UserKnownHostsFile $first names",
        ),
    };
  });
  final expanded = path.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (match) {
    final name = match[1]!;
    return environment[name] ??
        Platform.environment[name] ??
        (throw SshConfigException(
          "can't tell which file UserKnownHostsFile $first names: "
          '$name is not set',
        ));
  });
  final file = File(expanded);
  final isAbsolute = RegExp(r'^(/|[A-Za-z]:[\\/])').hasMatch(expanded);
  if (!isAbsolute || expanded == '/dev/null' || expanded == 'NUL') {
    throw SshConfigException(
      "UserKnownHostsFile $first isn't a file to add the key to",
    );
  }
  return file;
}

void _append(File file, List<String> entries) {
  try {
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
      // As ssh makes ~/.ssh: the user's alone.
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['700', file.parent.path]);
      }
    }
    final existing = file.existsSync() ? file.readAsStringSync() : '';
    final separator = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
    file.writeAsStringSync(
      '$separator${entries.map((entry) => '$entry\n').join()}',
      mode: FileMode.append,
      flush: true,
    );
  } on FileSystemException catch (exception) {
    throw SshException(
      "couldn't add the host key to ${file.path}: ${exception.message}",
    );
  }
}
