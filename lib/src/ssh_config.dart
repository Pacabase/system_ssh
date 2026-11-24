import 'dart:async';
import 'dart:convert';

import 'abort_signal.dart';
import 'processes.dart';
import 'ssh_command.dart';
import 'ssh_target.dart';

/// What `ssh -G` says ~/.ssh/config makes of [server], by option name, or
/// empty when it can't tell.
Future<Map<String, String>> resolveConfig(
  SshTarget server, {
  String executable = 'ssh',
  Map<String, String> environment = const {},
  Duration timeout = const Duration(seconds: 5),
  Future<void>? abortTrigger,
}) async {
  final abort = AbortSignal(abortTrigger);

  final process = await startWatched([
    executable,
    '-G',
    ...destinationArguments(server),
  ], environment: environment);
  unawaited(process.stderr.drain<void>());
  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .toList();

  try {
    final code = await abort.exitCodeOf(process, timeout: timeout);
    return code == 0 ? parseConfig(await output) : const {};
  } on TimeoutException {
    // A `Match exec` in ~/.ssh/config can hang.
    return const {};
  }
}

/// `ssh -G` output as option name to value. An option ssh lists more than
/// once, such as `identityfile`, keeps its last value, except for the files
/// [repeatedFiles] names, whose values are joined with newlines.
Map<String, String> parseConfig(List<String> lines) {
  final config = <String, String>{};
  for (final line in lines.map((line) => line.trim())) {
    final space = line.indexOf(' ');
    if (space <= 0) continue;

    final name = line.substring(0, space).toLowerCase();
    final value = line.substring(space + 1).trim();
    config[name] = repeatedFiles.contains(name) && config[name] != null
        ? '${config[name]}\n$value'
        : value;
  }
  return config;
}

/// The options ssh may list several times, each a file whose path can appear
/// in a prompt.
const repeatedFiles = {'identityfile', 'certificatefile'};
