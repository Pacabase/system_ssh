import 'dart:io';

import 'exceptions.dart';
import 'windows_job.dart';

/// Starts [command] so it, and the ProxyCommand or ProxyJump ssh it runs, dies
/// with this process, even a killed or crashed one. [Process.kill] on the
/// result stops them.
Future<Process> startWatched(List<String> command) => _start(
      () => Platform.isWindows
          ? startInJob(command)
          : Process.start('/bin/sh', ['-c', _dieWithParent, 'sh', ...command]),
    );

/// Starts [command] as is, but on Windows in a job, so [Process.kill] also
/// stops what it started.
Future<Process> startDirect(List<String> command) => _start(
      () => Platform.isWindows
          ? startInJob(command)
          : Process.start(command.first, command.sublist(1)),
    );

/// [executable] as an absolute path on Windows, where a bare name would be
/// looked up in the working directory before the `PATH`.
String resolveExecutable(String executable) {
  if (!Platform.isWindows || executable.contains(RegExp(r'[\\/]'))) {
    return executable;
  }

  final name = executable.toLowerCase().endsWith('.exe')
      ? executable
      : '$executable.exe';
  final found = (Platform.environment['PATH'] ?? '')
      .split(';')
      .map((directory) => directory.replaceAll('"', ''))
      .where((directory) => directory.isNotEmpty && File(directory).isAbsolute)
      .map((directory) => '$directory\\$name')
      .where((path) => File(path).existsSync())
      .firstOrNull;
  if (found == null) throw const SshNotFoundException();

  return found;
}

Future<Process> _start(Future<Process> Function() start) async {
  try {
    return await start();
  } on ProcessException {
    throw const SshNotFoundException();
  }
}

// stdin hits EOF however this process dies. `stop` also kills ssh's children,
// since ssh only stops its ProxyCommand once connected.
const _dieWithParent = r'''
stop() { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
term=
trap 'term=1' TERM
"$@" & pid=$!
exec 3<&0
{ read _ <&3; stop; } & watcher=$!
trap 'stop; kill $watcher 2>/dev/null; wait $pid; exit 143' TERM
[ -z "$term" ] || kill -TERM $$
wait $pid
status=$?
kill $watcher 2>/dev/null
exit $status
''';
