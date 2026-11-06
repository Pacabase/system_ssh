import 'dart:async';
import 'dart:io';

import 'exceptions.dart';
import 'windows_job.dart';
import 'wrapped_process.dart';

/// Starts [command] so it, and the ProxyCommand or ProxyJump ssh it runs, dies
/// with this process, even a killed or crashed one. [Process.kill] on the
/// result stops them.
///
/// The command is this process's own child, since 1Password's prompt on Linux
/// names the parent of ssh, which would otherwise be a shell.
Future<Process> startWatched(
  List<String> command, {
  Map<String, String> environment = const {},
}) =>
    _start(
      () => Platform.isWindows
          ? startInJob(command, environment: environment)
          : _WatchedChild.start(command, environment: environment),
    );

/// A command beside a shell that stops it, and its children, once the shell's
/// stdin hits EOF however this process dies. Linux's own parent-death signal is
/// no use: it fires when the thread that started the command exits, and Dart's
/// idle threads do.
final class _WatchedChild extends WrappedProcess {
  _WatchedChild._(super.process, this._watcher) {
    unawaited(process.exitCode.then((_) => _hasExited = true));
    unawaited(_watcher.exitCode.then((_) => _isWatched = false));
  }

  static Future<Process> start(
    List<String> command, {
    required Map<String, String> environment,
  }) async {
    // sh waits for the watcher, then becomes the command in the same process,
    // which exits 127 if the command is missing. Like a background job, it
    // reads /dev/null and ignores a terminal's Ctrl-C.
    final process = await Process.start(
      '/bin/sh',
      [
        '-c',
        r'''trap '' INT QUIT; read _ || exit 1; exec "$@" </dev/null''',
        'sh',
        ...command,
      ],
      environment: environment,
    );

    final Process watcher;
    try {
      watcher = await Process.start(
        '/bin/sh',
        ['-c', _stopOnEof, 'sh', '${process.pid}'],
        environment: environment,
      );
    } on ProcessException {
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      _close(process.stdin);
      throw const SshException('could not start the shell that watches ssh');
    }
    unawaited(watcher.stdout.drain<void>());
    unawaited(watcher.stderr.drain<void>());
    unawaited(process.exitCode.then((_) => watcher.kill()));

    process.stdin.writeln();
    _close(process.stdin);
    return _WatchedChild._(process, watcher);
  }

  final Process _watcher;
  var _hasExited = false;
  var _isWatched = true;
  var _isTerminated = false;

  /// 143 once [kill] terminated it, whatever the command exits with, and a
  /// signal's 128 + its number, as a shell reports them.
  @override
  Future<int> get exitCode => process.exitCode.then(
        (code) => _isTerminated ? 143 : (code < 0 ? 128 - code : code),
      );

  /// TERM goes through the watcher, which stops the command's children first:
  /// ssh only stops its ProxyCommand once connected.
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    // Its pid may be another process's by now.
    if (_hasExited) return false;
    if (signal != ProcessSignal.sigterm) return process.kill(signal);

    _isTerminated = true;
    if (!_isWatched) return process.kill(signal);
    _close(_watcher.stdin);
    return true;
  }

  // A shell that died first breaks the pipe, which is no error here.
  static void _close(IOSink stdin) =>
      unawaited(stdin.close().then((_) {}, onError: (Object _) {}));
}

// Waits for this process to die or kill the command, either of which closes
// the shell's stdin, then stops $1.
const _stopOnEof = r'''
trap '' INT QUIT
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
