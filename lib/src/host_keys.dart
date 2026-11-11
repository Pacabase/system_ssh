import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
final _added = RegExp(r"^Warning: Permanently added '([^']+)' \((\S+)\)");
final _known = RegExp(r"^debug\d: Host '.+' is known and matches the ");

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

  if (changedHostKey(log) case final hostKey?) {
    return SshHostKeyChangedException(
      hostKey,
      log: log,
      exitCode: exception.exitCode,
    );
  }

  if (!asksAboutHostKeys(config)) return null;
  final expected = knownHostsName(config);
  for (final (index, line) in log.indexed) {
    final match = _unknown.firstMatch(line);
    if (match == null) continue;

    final host = match[2]!;
    // A ProxyJump host's own ssh gets none of our options; only ours is ours.
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
    );
    if (changedHostKey(log) case final changed?) {
      throw SshHostKeyChangedException(changed, log: log, exitCode: code);
    }

    final entries =
        read.readAsLinesSync().where((line) => line.trim().isNotEmpty).toList();
    final addedAt = log.lastIndexWhere(_added.hasMatch);
    if (entries.isEmpty &&
        log.any(_known.hasMatch) &&
        _lastFingerprint(log) == hostKey.fingerprint) {
      return;
    }
    if (entries.isEmpty || addedAt < 0) {
      if (code == 127) throw SshNotFoundException();
      throw tunnelFailure(log, code);
    }

    final offered = _lastFingerprint(log.take(addedAt));
    if (offered != hostKey.fingerprint) {
      throw SshHostKeyChangedException(
        SshHostKey(
          host: hostKey.host,
          type: _added.firstMatch(log[addedAt])![2]!,
          fingerprint: offered ?? 'unknown',
        ),
        log: log,
        exitCode: code,
      );
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
}) async {
  final aborted = Completer<void>();
  unawaited(abortTrigger?.then((_) => aborted.complete(), onError: (_) {}));

  final process = await startWatched(command, environment: environment);
  unawaited(process.stdout.drain<void>());
  final lines = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .map((line) {
    logger.fine(line);
    return line;
  }).toList();

  try {
    final code = await Future.any([
      process.exitCode,
      aborted.future.then((_) => throw const SshTunnelAbortedException()),
    ]).timeout(timeout);
    return (await lines.timeout(timeout, onTimeout: () => const []), code);
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

/// The file ssh adds new host keys to: the first `UserKnownHostsFile`.
File userKnownHostsFile(
  Map<String, String> config, {
  Map<String, String> environment = const {},
}) {
  final home = (environment['HOME'] ??
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '')
      .replaceAll(r'\', '/');
  final first = userKnownHostsFiles(config).first;

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
  return File(path);
}

void _append(File file, List<String> entries) {
  try {
    file.parent.createSync(recursive: true);
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
