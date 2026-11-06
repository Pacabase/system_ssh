import 'dart:async';
import 'dart:io';

import 'exceptions.dart';
import 'windows_job.dart';

/// Starts [command] so it, and the ProxyCommand or ProxyJump ssh it runs, dies
/// with this process, even a killed or crashed one. [Process.kill] on the
/// result stops them.
///
/// On Linux the command is this process's own child, since 1Password's prompt
/// there names the parent of ssh, which would otherwise be a shell.
Future<Process> startWatched(
  List<String> command, {
  Map<String, String> environment = const {},
}) =>
    _start(() async {
      if (Platform.isWindows) {
        return startInJob(command, environment: environment);
      }
      if (Platform.isLinux) {
        return _WatchedChild.start(command, environment: environment);
      }
      return Process.start(
        '/bin/sh',
        ['-c', _dieWithParent, 'sh', ...command],
        environment: environment,
      );
    });

/// A command beside a shell that stops it, and its children, once the shell's
/// stdin hits EOF however this process dies, as _dieWithParent does from above.
/// Linux's own parent-death signal is no use: it fires when the thread that
/// started the command exits, and Dart's idle threads do.
final class _WatchedChild implements Process {
  _WatchedChild._(this._process) {
    unawaited(_process.exitCode.then((_) => _hasExited = true));
  }

  static Future<Process> start(
    List<String> command, {
    required Map<String, String> environment,
  }) async {
    // sh becomes the command in the same process, so it is still this process's
    // child, exits 127 if the command is missing, and reads /dev/null, as a
    // background job in _dieWithParent does.
    final process = await Process.start(
      '/bin/sh',
      ['-c', r'exec "$@" </dev/null', 'sh', ...command],
      environment: environment,
    );

    final Process watcher;
    try {
      watcher = await Process.start('/bin/sh', [
        '-c',
        _stopOnEof,
        'sh',
        '${process.pid}',
      ]);
    } on ProcessException {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }
    unawaited(watcher.stdout.drain<void>());
    unawaited(watcher.stderr.drain<void>());
    unawaited(process.exitCode.then((_) => watcher.kill()));
    return _WatchedChild._(process);
  }

  final Process _process;
  var _hasExited = false;
  var _isTerminated = false;

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  /// Nothing reads it: the command reads /dev/null.
  @override
  IOSink get stdin => _process.stdin;

  /// 143 once [kill] terminated it, whatever the command exits with, and a
  /// signal's 128 + its number, as _dieWithParent's shell reports them.
  @override
  Future<int> get exitCode => _process.exitCode.then(
        (code) => _isTerminated ? 143 : (code < 0 ? 128 - code : code),
      );

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    // Its pid may be another process's by now.
    if (_hasExited) return false;
    if (signal == ProcessSignal.sigterm) _isTerminated = true;
    // ssh only stops its ProxyCommand once connected. The watcher stops once
    // the command exits.
    for (final child in _children(pid)) {
      Process.killPid(child, signal);
    }
    return _process.kill(signal);
  }

  // Linux lists children per thread, and a command can start them from any.
  static List<int> _children(int pid) {
    try {
      return [
        for (final thread in Directory('/proc/$pid/task').listSync())
          ...File('${thread.path}/children')
              .readAsStringSync()
              .split(' ')
              .map(int.tryParse)
              .nonNulls,
      ];
    } on FileSystemException {
      return const [];
    }
  }
}

// Waits for this process to die, which closes the shell's stdin, then stops $1.
const _stopOnEof = r'''
read _
pkill -TERM -P "$1" 2>/dev/null
kill "$1" 2>/dev/null
''';

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
