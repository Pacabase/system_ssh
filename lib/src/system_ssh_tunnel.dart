import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'exceptions.dart';
import 'logger.dart';
import 'ssh_client.dart';
import 'ssh_command.dart';
import 'ssh_log.dart';
import 'ssh_output.dart';

const _tailLength = 20;

/// A forward that is up: ssh's own process, or a share of a master's.
abstract interface class ForwardHandle {
  /// Completes when [close] stops it, or fails saying why it went down.
  Future<void> get done;

  /// Stops it. Closing again does nothing.
  Future<void> close();
}

final class SystemSshTunnel implements SshTunnel {
  SystemSshTunnel(this.localPort, this._forward);

  /// Waits for ssh to have bound the forward on [localPort]. [onLog] gets
  /// each line ssh writes until then, and its warnings and failed connections
  /// after. Every line also goes to the `system_ssh` logger.
  static Future<SystemSshTunnel> attach(
    Process process, {
    required int localPort,
    String bindAddress = '127.0.0.1',
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      SystemSshTunnel(
        localPort,
        await ForwardProcess.attach(
          process,
          readiness: LocalForwardReadiness(localPort),
          describe: () => '${bracketIPv6(bindAddress)}:$localPort',
          onLog: onLog,
          abortTrigger: abortTrigger,
        ),
      );

  @override
  final int localPort;

  final ForwardHandle _forward;

  @override
  Future<void> get done => _forward.done;

  @override
  Future<void> close() => _forward.close();
}

final class SystemSshRemoteTunnel implements SshRemoteTunnel {
  SystemSshRemoteTunnel(this.remotePort, this._forward);

  /// Waits for the server to have accepted the forward [readiness] watches,
  /// with [onLog] as in [SystemSshTunnel.attach].
  static Future<SystemSshRemoteTunnel> attach(
    Process process, {
    required RemoteForwardReadiness readiness,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async {
    final forward = await ForwardProcess.attach(
      process,
      readiness: readiness,
      describe: () =>
          "the server's 127.0.0.1:${readiness.port ?? readiness.requestedPort}",
      onLog: onLog,
      abortTrigger: abortTrigger,
    );
    return SystemSshRemoteTunnel(readiness.port!, forward);
  }

  @override
  final int remotePort;

  final ForwardHandle _forward;

  @override
  Future<void> get done => _forward.done;

  @override
  Future<void> close() => _forward.close();
}

/// ssh running one forward, local or remote, or a master serving several.
final class ForwardProcess implements ForwardHandle {
  ForwardProcess._(this._process, this.done, this._describe) {
    unawaited(_process.exitCode.then((_) => _hasExited = true));
    // A caller that never listens to done must not crash on a dropped tunnel.
    done.ignore();
  }

  /// Completes when [close] stops ssh, or fails saying why it exited.
  @override
  final Future<void> done;

  final Process _process;
  final String Function() _describe;
  bool _hasExited = false;
  bool _isClosed = false;

  /// Waits until [readiness] says ssh's forward is up. [onLog] gets ssh's
  /// lines until then, and its warnings and failed connections after, unless
  /// [onLineAfterReady] takes every line after instead.
  static Future<ForwardProcess> attach(
    Process process, {
    required ForwardReadiness readiness,
    required String Function() describe,
    void Function(SshLog log)? onLog,
    void Function(String line)? onLineAfterReady,
    Future<void>? abortTrigger,
  }) async {
    final lines = <String>[];
    final tail = <String>[];
    final ready = Completer<void>();
    final stderrDone = Completer<void>();

    late final ForwardProcess forward;
    void report(SshLog entry) => reportTo(onLog, entry);

    void onLine(String line) {
      logger.fine(line);
      if (ready.isCompleted) {
        tail.add(line);
        if (tail.length > _tailLength) tail.removeAt(0);
        // Once closed, what's left is ssh saying goodbye: "Killed by signal 15."
        if (forward._isClosed || line.trim().isEmpty) return;
        if (onLineAfterReady != null) return onLineAfterReady(line);
        if (classify(line) case final entry when entry is! SshProgress) {
          report(entry);
        }
        return;
      }

      lines.add(line);
      if (line.trim().isNotEmpty) report(classify(line));
      if (readiness.isReadyAfter(line)) ready.complete();
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
        if (forward._isClosed) return;
        throw tunnelFailure(tail, code);
      }
      ready.completeError(tunnelFailure(lines, code));
    }

    forward = ForwardProcess._(process, waitForExit(), describe);
    unawaited(
      abortTrigger?.then((_) {
        if (!ready.isCompleted) {
          ready.completeError(const SshTunnelAbortedException());
        }
      }, onError: (_) {}),
    );

    try {
      await ready.future;
    } catch (exception) {
      await forward.close();
      rethrow;
    }

    logger.info('Tunnel ready on ${describe()}');
    return forward;
  }

  /// Stops ssh. Closing again does nothing.
  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    logger.info('Closing tunnel on ${_describe()}');
    // Once exited, the pid may already belong to another process.
    if (!_hasExited) _process.kill();
    try {
      await done.timeout(const Duration(seconds: 2), onTimeout: () {});
    } on SshTunnelException {
      // It had already dropped; done says why.
    }
  }
}
