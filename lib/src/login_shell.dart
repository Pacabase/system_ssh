import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'exceptions.dart';
import 'processes.dart';

final _loginShell = CachedEnvironment(loginShellEnvironment);

Future<Map<String, String>> cachedLoginShellEnvironment() => _loginShell.read();

/// Keeps the first environment [_read] returns, sharing one read between
/// concurrent callers. A failed read (null) gives them an empty environment
/// and isn't kept, nor is one that throws, so one slow shell start doesn't cost
/// every later tunnel the user's `PATH` and agent.
final class CachedEnvironment {
  CachedEnvironment(this._read);

  final Future<Map<String, String>?> Function() _read;
  Future<Map<String, String>>? _environment;

  Future<Map<String, String>> read() => _environment ??= _read().then(
    (environment) {
      if (environment != null) return environment;
      _environment = null;
      return const {};
    },
    onError: (Object error, StackTrace stackTrace) {
      _environment = null;
      Error.throwWithStackTrace(error, stackTrace);
    },
  );
}

/// Null when the shell fails or outlasts [timeout]. Empty on Windows, where
/// apps get the user's `PATH` already.
Future<Map<String, String>?> loginShellEnvironment({
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (Platform.isWindows) return const {};

  final shell = Platform.environment['SHELL'] ?? '';
  return shellEnvironment(shell.isEmpty ? '/bin/sh' : shell, timeout: timeout);
}

Future<Map<String, String>?> shellEnvironment(
  String shell, {
  required Duration timeout,
}) async {
  final random = Random.secure();
  final marker =
      'system_ssh_'
      '${List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join()}';

  // startWatched gives the shell /dev/null as stdin.
  final Process process;
  try {
    process = await startWatched([
      shell,
      '-l',
      '-i',
      '-c',
      "printf '%s' $marker; env -0; printf '%s' $marker",
    ]);
  } on SshException {
    return null;
  }
  unawaited(process.stderr.drain<void>());
  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();

  try {
    final (code, text) = await (process.exitCode, output).wait.timeout(timeout);

    return code == 0 ? parseShellEnvironment(text, marker) : null;
  } on TimeoutException {
    process.kill();
    return null;
  }
}

Map<String, String>? parseShellEnvironment(String output, String marker) {
  final start = output.indexOf(marker);
  final end = start < 0 ? -1 : output.indexOf(marker, start + marker.length);
  if (end < 0) return null;

  final body = output.substring(start + marker.length, end);
  if (!body.endsWith('\x00')) return null;

  final entries = body.substring(0, body.length - 1).split('\x00');
  if (entries.any((entry) => entry.indexOf('=') < 1)) return null;

  return {
    for (final entry in entries)
      if (entry.substring(0, entry.indexOf('=')) case final name
          when _isKept(name))
        name: entry.substring(entry.indexOf('=') + 1),
  };
}

bool _isKept(String name) =>
    const {'PATH', 'HOME', 'DISPLAY'}.contains(name) || name.startsWith('SSH_');
