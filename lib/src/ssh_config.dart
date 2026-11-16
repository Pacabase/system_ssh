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

  final process = await startWatched(
    [executable, '-G', ...destinationArguments(server)],
    environment: environment,
  );
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

/// `ssh -G` output as option name to value.
Map<String, String> parseConfig(List<String> lines) => {
      for (final line in lines.map((line) => line.trim()))
        if (line.indexOf(' ') case final space when space > 0)
          line.substring(0, space).toLowerCase():
              line.substring(space + 1).trim(),
    };
