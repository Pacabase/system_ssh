import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'exceptions.dart';
import 'processes.dart';

Future<Map<String, String>>? _cached;

Future<Map<String, String>> cachedLoginShellEnvironment() =>
    _cached ??= loginShellEnvironment();

/// Empty when the shell fails or outlasts [timeout], and on Windows, where apps
/// get the user's `PATH` already.
Future<Map<String, String>> loginShellEnvironment({
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (Platform.isWindows) return const {};

  final shell = Platform.environment['SHELL'] ?? '';
  return shellEnvironment(shell.isEmpty ? '/bin/sh' : shell, timeout: timeout);
}

Future<Map<String, String>> shellEnvironment(
  String shell, {
  required Duration timeout,
}) async {
  final random = Random.secure();
  final marker = 'system_ssh_'
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
    return const {};
  }
  unawaited(process.stderr.drain<void>());
  final output =
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();

  try {
    final (code, text) = await (process.exitCode, output).wait.timeout(timeout);

    return code == 0 ? parseShellEnvironment(text, marker) : const {};
  } on TimeoutException {
    process.kill();
    return const {};
  }
}

Map<String, String> parseShellEnvironment(String output, String marker) {
  final start = output.indexOf(marker);
  final end = start < 0 ? -1 : output.indexOf(marker, start + marker.length);
  if (end < 0) return const {};

  final body = output.substring(start + marker.length, end);
  if (!body.endsWith('\x00')) return const {};

  final entries = body.substring(0, body.length - 1).split('\x00');
  if (entries.any((entry) => entry.indexOf('=') < 1)) return const {};

  return {
    for (final entry in entries)
      if (entry.substring(0, entry.indexOf('=')) case final name
          when _isKept(name))
        name: entry.substring(entry.indexOf('=') + 1),
  };
}

bool _isKept(String name) =>
    const {'PATH', 'HOME', 'DISPLAY'}.contains(name) || name.startsWith('SSH_');
