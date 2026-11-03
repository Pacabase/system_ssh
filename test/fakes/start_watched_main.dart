import 'dart:async';
import 'dart:io';

import 'package:system_ssh/src/processes.dart';

/// Runs its arguments through `startWatched`, then prints its own pid, the
/// one to kill, and hangs.
Future<void> main(List<String> command) async {
  await startWatched(command);
  stdout.writeln(pid);
  await stdout.flush();
  await Future<void>.delayed(const Duration(hours: 1));
}
