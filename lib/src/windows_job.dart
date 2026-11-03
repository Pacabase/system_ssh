import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'exceptions.dart';
import 'logger.dart';

/// Starts [command] in a job object that Windows kills when this process
/// exits, however it exits. [Process.kill] on the result kills the whole job.
Future<Process> startInJob(List<String> command) async {
  final job = _createJob();
  final Process process;
  try {
    process = await Process.start(command.first, command.sublist(1));
  } catch (_) {
    _closeHandle(job);
    rethrow;
  }

  // A child ssh starts before this assignment stays outside the job.
  final handle =
      _openProcess(_processSetQuota | _processTerminate, 0, process.pid);
  final isAssigned =
      handle != nullptr && _assignProcessToJobObject(job, handle) != 0;
  if (handle != nullptr) _closeHandle(handle);
  if (!isAssigned) {
    logger.warning('Could not tie ${command.first} to this process; '
        'it may outlive a crash');
  }

  return _JobProcess(process, job);
}

_Handle _createJob() {
  final job = _createJobObject(nullptr, nullptr);
  if (job == nullptr) {
    throw const SshException('could not create a Windows job object');
  }

  final limits = calloc<_ExtendedLimits>();
  try {
    limits.ref.basic.limitFlags = _jobObjectLimitKillOnJobClose;
    final isSet = _setInformationJobObject(
          job,
          _jobObjectExtendedLimitInformation,
          limits.cast(),
          sizeOf<_ExtendedLimits>(),
        ) !=
        0;
    if (!isSet) {
      _closeHandle(job);
      throw const SshException('could not set up a Windows job object');
    }
  } finally {
    calloc.free(limits);
  }

  return job;
}

final class _JobProcess implements Process {
  _JobProcess(this._process, this._job) {
    unawaited(_process.exitCode.then((_) => _close()));
  }

  final Process _process;
  _Handle? _job;

  @override
  int get pid => _process.pid;

  @override
  IOSink get stdin => _process.stdin;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final job = _job;
    final isTerminated = job != null && _terminateJobObject(job, 1) != 0;

    return _process.kill(signal) || isTerminated;
  }

  // Closing the last handle kills whatever ssh left running in the job.
  void _close() {
    final job = _job;
    if (job == null) return;

    _job = null;
    _closeHandle(job);
  }
}

typedef _Handle = Pointer<Void>;

const _jobObjectLimitKillOnJobClose = 0x2000;
const _jobObjectExtendedLimitInformation = 9;
const _processSetQuota = 0x0100;
const _processTerminate = 0x0001;

final class _BasicLimits extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @Size()
  external int minimumWorkingSetSize;

  @Size()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @UintPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

final class _ExtendedLimits extends Struct {
  external _BasicLimits basic;

  @Array(6)
  external Array<Uint64> ioCounters;

  @Size()
  external int processMemoryLimit;

  @Size()
  external int jobMemoryLimit;

  @Size()
  external int peakProcessMemoryUsed;

  @Size()
  external int peakJobMemoryUsed;
}

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _createJobObject = _kernel32.lookupFunction<
    _Handle Function(_Handle, _Handle),
    _Handle Function(_Handle, _Handle)>('CreateJobObjectW');

final _setInformationJobObject = _kernel32.lookupFunction<
    Int32 Function(_Handle, Int32, _Handle, Uint32),
    int Function(_Handle, int, _Handle, int)>(
  'SetInformationJobObject',
);

final _openProcess = _kernel32.lookupFunction<
    _Handle Function(Uint32, Int32, Uint32),
    _Handle Function(int, int, int)>('OpenProcess');

final _assignProcessToJobObject = _kernel32.lookupFunction<
    Int32 Function(_Handle, _Handle),
    int Function(_Handle, _Handle)>('AssignProcessToJobObject');

final _terminateJobObject = _kernel32.lookupFunction<
    Int32 Function(_Handle, Uint32),
    int Function(_Handle, int)>('TerminateJobObject');

final _closeHandle =
    _kernel32.lookupFunction<Int32 Function(_Handle), int Function(_Handle)>(
        'CloseHandle');
