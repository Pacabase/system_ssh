import 'dart:io';

import 'exceptions.dart';
import 'windows_job.dart';

/// Starts [command] so it, and the ProxyCommand or ProxyJump ssh it runs, dies
/// with this process, even a killed or crashed one. [Process.kill] on the
/// result stops them.
Future<Process> startWatched(
  List<String> command, {
  Map<String, String> environment = const {},
}) =>
    _start(
      () => Platform.isWindows
          ? startInJob(command, environment: environment)
          : Process.start(
              '/bin/sh',
              ['-c', _dieWithParent, 'sh', ...command],
              environment: environment,
            ),
    );

/// An absolute path on Windows, where a bare name is looked up in the working
/// directory first.
String resolveExecutable(
  String executable, {
  Map<String, String> environment = const {},
}) {
  if (!Platform.isWindows || executable.contains(RegExp(r'[\\/]'))) {
    return executable;
  }

  // Windows variable names are case-insensitive.
  final path = environment.entries
      .where((entry) => entry.key.toUpperCase() == 'PATH')
      .lastOrNull
      ?.value;

  final name = executable.toLowerCase().endsWith('.exe')
      ? executable
      : '$executable.exe';
  return _find(name, path ?? Platform.environment['PATH'] ?? '') ??
      (throw SshNotFoundException());
}

String? _find(String name, String path) => path
    .split(';')
    .map((directory) => directory.replaceAll('"', ''))
    .where((directory) => directory.isNotEmpty && File(directory).isAbsolute)
    .map((directory) => '$directory\\$name')
    .where((candidate) => File(candidate).existsSync())
    .firstOrNull;

Future<Process> _start(Future<Process> Function() start) async {
  try {
    return await start();
  } on ProcessException {
    throw SshNotFoundException();
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
