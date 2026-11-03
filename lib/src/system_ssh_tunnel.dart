import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'exceptions.dart';
import 'failure_message.dart';
import 'logger.dart';
import 'ssh_client.dart';

final class SystemSshTunnel implements SshTunnel {
  SystemSshTunnel._(this.localPort, this._process, this.done) {
    unawaited(_process.exitCode.then((_) => _hasExited = true));
  }

  @override
  final int localPort;

  @override
  final Future<void> done;

  final Process _process;
  bool _hasExited = false;
  bool _isClosed = false;

  /// Waits for ssh to have bound the forward. [onLog] gets each stderr line
  /// until then; every line also goes to the `system_ssh` logger.
  static Future<SystemSshTunnel> attach(
    Process process, {
    required int localPort,
    void Function(String line)? onLog,
    Future<void>? abortTrigger,
  }) async {
    final log = <String>[];
    final ready = Completer<void>();
    final listening = RegExp(
      'Local forwarding listening on 127\\.0\\.0\\.1 port $localPort\\b',
    );
    var isListening = false;
    final stderrDone = Completer<void>();

    void onLine(String line) {
      logger.fine(line);
      if (ready.isCompleted) return;

      log.add(line);
      try {
        onLog?.call(line);
      } catch (exception, stack) {
        logger.warning('onLog threw', exception, stack);
      }
      // ssh logs the listener before binding; only a started session means it bound.
      if (listening.hasMatch(line)) isListening = true;
      if (isListening && line.contains('Entering interactive session')) {
        ready.complete();
      }
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
      if (ready.isCompleted) return;

      final reason = failureMessage(log);
      ready.completeError(
        SshTunnelException(
          reason.isEmpty ? 'ssh exited with code $code' : reason,
          log: log,
          exitCode: code,
        ),
      );
    }

    final tunnel = SystemSshTunnel._(localPort, process, waitForExit());
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
    await done.timeout(const Duration(seconds: 2), onTimeout: () {});
  }
}
