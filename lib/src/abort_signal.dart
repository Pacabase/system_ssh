import 'dart:async';
import 'dart:io';

import 'exceptions.dart';

final class AbortSignal {
  AbortSignal(Future<void>? trigger) {
    _aborted.future.ignore();
    unawaited(
      trigger?.then(
        (_) => _aborted.completeError(const SshTunnelAbortedException()),
        onError: (Object _) {},
      ),
    );
  }

  final _aborted = Completer<Never>();

  bool get isAborted => _aborted.isCompleted;

  void throwIfAborted() {
    if (isAborted) throw const SshTunnelAbortedException();
  }

  /// Fails with [SshTunnelAbortedException] once aborted, and never
  /// completes otherwise.
  Future<Never> get aborted => _aborted.future;

  /// The exit code of [process]. It throws a [TimeoutException] when the
  /// process outlasts [timeout], or an [SshTunnelAbortedException] when this
  /// is aborted first, and kills the process either way, so a hung ssh or
  /// `Match exec` never outlives the attempt.
  Future<int> exitCodeOf(Process process, {required Duration timeout}) async {
    try {
      return await Future.any([process.exitCode, aborted]).timeout(timeout);
    } catch (exception) {
      process.kill();
      rethrow;
    }
  }
}
