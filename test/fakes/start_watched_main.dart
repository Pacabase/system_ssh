import 'dart:async';
import 'dart:io';

import 'package:system_ssh/src/processes.dart';

/// Runs its arguments through `startWatched`, then prints its own pid, the
/// one to kill, and hangs. What the command writes, and its exit code if it
/// exits, go to stderr, so a test that finds it gone can say why.
Future<void> main(List<String> command) async {
  final watched = await startWatched(command);
  watched.stdout.listen(stderr.add);
  watched.stderr.listen(stderr.add);
  unawaited(
    watched.exitCode.then((code) => stderr.writeln('command exited $code')),
  );
  stdout.writeln(pid);
  await stdout.flush();
  await Future<void>.delayed(const Duration(hours: 1));
}
