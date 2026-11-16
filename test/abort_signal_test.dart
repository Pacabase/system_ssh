import 'dart:async';
import 'dart:io';

import 'package:system_ssh/src/abort_signal.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  group('AbortSignal', () {
    test('is aborted once the trigger completes', () async {
      final trigger = Completer<void>();
      final signal = AbortSignal(trigger.future);

      expect(signal.isAborted, isFalse);
      signal.throwIfAborted();

      trigger.complete();
      await pumpEventQueue();

      expect(signal.isAborted, isTrue);
      expect(signal.throwIfAborted, throwsA(isA<SshTunnelAbortedException>()));
      await expectLater(
        signal.aborted,
        throwsA(isA<SshTunnelAbortedException>()),
      );
    });

    test('is never aborted without a trigger, or by one that fails', () async {
      final failing = AbortSignal(Future.error(StateError('gone')));
      final none = AbortSignal(null);
      await pumpEventQueue();

      expect(failing.isAborted, isFalse);
      expect(none.isAborted, isFalse);
    });

    test('gives the exit code of a process that exits', () async {
      final process = _FakeProcess()..exit(3);

      expect(
        await AbortSignal(null).exitCodeOf(process, timeout: _long),
        3,
      );
      expect(process.kills, 0);
    });

    test('leaves a process that exits before the abort', () async {
      final trigger = Completer<void>();
      final process = _FakeProcess()..exit(0);

      expect(
        await AbortSignal(trigger.future).exitCodeOf(process, timeout: _long),
        0,
      );
      trigger.complete();
      await pumpEventQueue();

      expect(process.kills, 0);
    });

    test('kills a process at once for a trigger already completed', () async {
      final process = _FakeProcess();

      await expectLater(
        AbortSignal(Future.value()).exitCodeOf(process, timeout: _long),
        throwsA(isA<SshTunnelAbortedException>()),
      );
      expect(process.kills, 1);
    });

    test('kills a process when aborted', () async {
      final trigger = Completer<void>();
      final process = _FakeProcess();
      final exitCode =
          AbortSignal(trigger.future).exitCodeOf(process, timeout: _long);

      trigger.complete();

      await expectLater(exitCode, throwsA(isA<SshTunnelAbortedException>()));
      expect(process.kills, 1);
    });

    test('kills a process that outlasts the timeout', () async {
      final process = _FakeProcess();

      await expectLater(
        AbortSignal(null).exitCodeOf(process, timeout: Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      expect(process.kills, 1);
    });
  });
}

const _long = Duration(minutes: 1);

/// A [Process] that exits when a test says so, or when killed.
final class _FakeProcess implements Process {
  final _exitCode = Completer<int>();
  int kills = 0;

  void exit(int code) => _exitCode.complete(code);

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!_exitCode.isCompleted) _exitCode.complete(-15);
    return true;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
