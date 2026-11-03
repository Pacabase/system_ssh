import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:system_ssh/src/ports.dart';
import 'package:test/test.dart';

/// The compiled `fake_ssh_main.dart`.
final Future<String> fakeSshExecutable =
    compileExecutable('test/fakes/fake_ssh_main.dart');

/// [source], relative to the package root, compiled to an executable.
///
/// The executable is kept in a temp dir named for the source and the SDK, so
/// each test file, and each later run, reuses it.
Future<String> compileExecutable(String source) async {
  final file = File(source).absolute;
  final name = file.uri.pathSegments.last.replaceFirst(RegExp(r'\.dart$'), '');
  final fingerprint = _fnv1a([
    ...file.readAsBytesSync(),
    ...utf8.encode(Platform.version),
  ]).toRadixString(16);
  final directory = Directory(
    '${Directory.systemTemp.path}/system_ssh_${name}_$fingerprint',
  )..createSync(recursive: true);
  final executable = File(
    '${directory.path}/$name${Platform.isWindows ? '.exe' : ''}',
  );
  if (executable.existsSync()) return executable.path;

  // Test files compile in parallel; each writes its own file, then one wins.
  final output = File(
    '${executable.path}.$pid.${DateTime.now().microsecondsSinceEpoch}',
  );
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    '-o',
    output.path,
    file.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Could not compile $source:\n${result.stdout}');
  }
  try {
    output.renameSync(executable.path);
  } on FileSystemException {
    if (!executable.existsSync()) rethrow;
    output.deleteSync();
  }

  return executable.path;
}

int _fnv1a(List<int> bytes) => bytes.fold(
      0x811c9dc5,
      (hash, byte) => ((hash ^ byte) * 0x01000193) & 0xffffffff,
    );

/// The fake run directly, playing the steps in [arguments].
final class FakeCommand {
  FakeCommand._(this.arguments, this._record);

  /// The fake's command line.
  final List<String> arguments;

  final File _record;

  /// The fake's pid, once it has started.
  Future<int> get pid => eventually(() => pids.firstOrNull);

  /// The pid of the first child the fake started, once it has.
  Future<int> get childPid => eventually(() => pids.elementAtOrNull(1));

  /// The pids the fake recorded so far: its own, then its children's.
  List<int> get pids {
    if (!_record.existsSync()) return const [];

    final lines = _record.readAsStringSync().split('\n');
    return lines.take(lines.length - 1).map(int.tryParse).nonNulls.toList();
  }
}

/// The fake's command line for [steps]. Whatever it starts is killed when the
/// test ends.
Future<FakeCommand> fakeCommand(List<String> steps) async {
  final directory = Directory.systemTemp.createTempSync('fake_command');
  final record = File('${directory.path}/pids');
  final command = FakeCommand._(
    [await fakeSshExecutable, 'record:${record.path}', ...steps],
    record,
  );
  addTearDown(() {
    for (final pid in command.pids) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    deleteSoon(directory);
  });

  return command;
}

/// Starts the fake directly, running [steps], and kills it and what it
/// started when the test ends.
Future<Process> startFake(List<String> steps) async {
  final command = await fakeCommand(steps);
  final process = await Process.start(
    command.arguments.first,
    command.arguments.sublist(1),
  );
  addTearDown(() => process.kill(ProcessSignal.sigkill));

  return process;
}

/// Deletes [directory], unless a process Windows hasn't finished killing
/// still holds a file in it.
void deleteSoon(Directory directory) {
  try {
    directory.deleteSync(recursive: true);
  } on FileSystemException {
    // Left to the OS's temp cleanup.
  }
}

/// The exit code of a process [Process.kill] stopped: SIGTERM's on POSIX,
/// non-zero on Windows.
final Matcher terminated =
    Platform.isWindows ? isNot(0) : equals(-ProcessSignal.sigterm.signalNumber);

/// What [read] returns once it isn't null, polling until [timeout].
Future<T> eventually<T extends Object>(
  T? Function() read, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);

  for (;;) {
    if (read() case final value?) return value;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Still null after $timeout', timeout);
    }

    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// [process]'s exit code, failing the test if it takes over ten seconds.
Future<int> exitCodeOf(Process process) =>
    process.exitCode.timeout(const Duration(seconds: 10));

/// Whether a process with [pid] is running.
bool isRunning(int pid) {
  if (!Platform.isWindows) return _kill(pid, 0) == 0;

  final handle = _openProcess(_processQueryLimitedInformation, 0, pid);
  if (handle == nullptr) return false;

  final code = calloc<Uint32>();
  try {
    return _getExitCodeProcess(handle, code) != 0 && code.value == _stillActive;
  } finally {
    calloc.free(code);
    _closeHandle(handle);
  }
}

/// Whether [pid] is gone within a few seconds; Windows takes longer to
/// tear a process down.
Future<bool> stops(int pid) async {
  try {
    await eventually(
      () => isRunning(pid) ? null : true,
      timeout: Duration(seconds: Platform.isWindows ? 15 : 5),
    );
    return true;
  } on TimeoutException {
    return false;
  }
}

/// A `freePort` that counts how often it was called. Its constructor's
/// function picks each port, given the pick's number from 1; by default a
/// free one.
final class CountingPorts {
  CountingPorts([Future<int> Function(int pick)? port])
      : _port = port ?? ((_) => pickFreePort());

  final Future<int> Function(int pick) _port;
  int _picks = 0;

  /// How often [next] was called.
  int get picks => _picks;

  /// The next port.
  Future<int> next() => _port(++_picks);
}

final _kill = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
  'kill',
);

const _processQueryLimitedInformation = 0x1000;
const _stillActive = 259;

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _openProcess = _kernel32.lookupFunction<
    Pointer<Void> Function(Uint32, Int32, Uint32),
    Pointer<Void> Function(int, int, int)>('OpenProcess');

final _getExitCodeProcess = _kernel32.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Uint32>),
    int Function(Pointer<Void>, Pointer<Uint32>)>('GetExitCodeProcess');

final _closeHandle = _kernel32.lookupFunction<Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)>('CloseHandle');
