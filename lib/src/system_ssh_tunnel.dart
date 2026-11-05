import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'exceptions.dart';
import 'logger.dart';
import 'ssh_client.dart';
import 'ssh_log.dart';
import 'ssh_output.dart';

const _tailLength = 20;

final class SystemSshTunnel implements SshTunnel {
  SystemSshTunnel._(this.localPort, this._process, this.done) {
    unawaited(_process.exitCode.then((_) => _hasExited = true));
    // A caller that never listens to done must not crash on a dropped tunnel.
    done.ignore();
  }

  @override
  final int localPort;

  @override
  final Future<void> done;

  final Process _process;
  bool _hasExited = false;
  bool _isClosed = false;

  /// Waits for ssh to have bound the forward. [onLog] gets each line ssh
  /// writes until then, and its warnings and failed connections after. Every
  /// line also goes to the `system_ssh` logger.
  static Future<SystemSshTunnel> attach(
    Process process, {
    required int localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async {
    final lines = <String>[];
    final tail = <String>[];
    final ready = Completer<void>();
    var isListening = false;
    final stderrDone = Completer<void>();

    late final SystemSshTunnel tunnel;
    void report(SshLog entry) {
      try {
        onLog?.call(entry);
      } catch (exception, stack) {
        logger.warning('onLog threw', exception, stack);
      }
    }

    void onLine(String line) {
      logger.fine(line);
      if (ready.isCompleted) {
        tail.add(line);
        if (tail.length > _tailLength) tail.removeAt(0);
        // Once closed, what's left is ssh saying goodbye: "Killed by signal 15."
        if (tunnel._isClosed || line.trim().isEmpty) return;
        if (classify(line) case final entry when entry is! SshProgress) {
          report(entry);
        }
        return;
      }

      lines.add(line);
      if (line.trim().isNotEmpty) report(classify(line));
      if (isListeningOn(line, localPort)) isListening = true;
      if (isListening && isSessionStarted(line)) ready.complete();
    }

    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          onLine,
          onError: (Object _) {},
          onDone: stderrDone.complete,
        );
    unawaited(process.stdout.drain<void>());

    Future<void> waitForExit() async {
      final code = await process.exitCode;
      // ssh's last lines, the ones that say why, can land after its exit code.
      await stderrDone.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      logger.info('ssh exited with code $code');
      if (ready.isCompleted) {
        if (tunnel._isClosed) return;

        final reason = failureMessage(tail);
        throw SshTunnelException(
          reason.isEmpty ? 'ssh exited with code $code' : reason,
          log: List.unmodifiable(tail),
          exitCode: code,
          isPermanent: isPermanentFailure(tail),
        );
      }

      final reason = failureMessage(lines);
      ready.completeError(
        SshTunnelException(
          reason.isEmpty ? 'ssh exited with code $code' : reason,
          log: lines,
          exitCode: code,
          isPermanent: isPermanentFailure(lines),
        ),
      );
    }

    tunnel = SystemSshTunnel._(localPort, process, waitForExit());
    unawaited(
      abortTrigger?.then((_) {
        if (!ready.isCompleted) {
          ready.completeError(const SshTunnelAbortedException());
        }
      }, onError: (_) {}),
    );

    try {
      await ready.future;
    } catch (_) {
      await tunnel.close();
      rethrow;
    }

    logger.info('Tunnel ready on 127.0.0.1:$localPort');
    return tunnel;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    logger.info('Closing tunnel on 127.0.0.1:$localPort');
    // Once exited, the pid may already belong to another process.
    if (!_hasExited) _process.kill();
    try {
      await done.timeout(const Duration(seconds: 2), onTimeout: () {});
    } on SshTunnelException {
      // It had already dropped; done says why.
    }
  }
}
