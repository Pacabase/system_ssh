import 'dart:async';
import 'dart:convert';

import 'exceptions.dart';
import 'processes.dart';
import 'ssh_command.dart';
import 'ssh_target.dart';

/// What `ssh -G` says ~/.ssh/config makes of [server], by option name, or
/// empty when it can't tell.
Future<Map<String, String>> resolveConfig(
  SshTarget server, {
  String executable = 'ssh',
  Duration timeout = const Duration(seconds: 5),
  Future<void>? abortTrigger,
}) async {
  final aborted = Completer<void>();
  unawaited(abortTrigger?.then((_) => aborted.complete(), onError: (_) {}));

  final process =
      await startDirect([executable, '-G', ...destinationArguments(server)]);
  unawaited(process.stderr.drain<void>());
  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .toList();

  try {
    final code = await Future.any([
      process.exitCode,
      aborted.future.then((_) => throw const SshTunnelAbortedException()),
    ]).timeout(timeout);

    return code == 0 ? parseConfig(await output) : const {};
  } on TimeoutException {
    // A `Match exec` in ~/.ssh/config can hang; it must not outlive the connect.
    process.kill();
    return const {};
  } on SshTunnelAbortedException {
    process.kill();
    rethrow;
  }
}

/// `ssh -G` output as option name to value.
Map<String, String> parseConfig(List<String> lines) => {
      for (final line in lines.map((line) => line.trim()))
        if (line.indexOf(' ') case final space when space > 0)
          line.substring(0, space).toLowerCase():
              line.substring(space + 1).trim(),
    };
