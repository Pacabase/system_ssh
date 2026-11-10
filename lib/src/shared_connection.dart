import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'exceptions.dart';
import 'logger.dart';
import 'processes.dart';
import 'ssh_command.dart';
import 'ssh_log.dart';
import 'ssh_output.dart';
import 'ssh_target.dart';
import 'system_ssh_tunnel.dart';

/// The ssh masters this process runs for `shareConnections`, one per server.
final connectionPool = ConnectionPool();

/// ssh masters this process owns, one per server, ssh and environment, that
/// tunnels share so the user logs in once.
final class ConnectionPool {
  /// A pool whose `-O forward` gives up after [forwardTimeout], and whose
  /// `-O cancel` after [cancelTimeout].
  ConnectionPool({
    this.forwardTimeout = const Duration(seconds: 15),
    this.cancelTimeout = const Duration(seconds: 2),
  });

  final Duration forwardTimeout;
  final Duration cancelTimeout;
  final _connections = <String, _Connection>{};

  /// A hold on the master for [server], started first unless one is up.
  /// [onLog] gets its lines while it connects. Release it once its forwards
  /// are added; each forward holds the master until it closes.
  Future<SharedConnection> connect(
    SshTarget server, {
    required String executable,
    required Map<String, String> environment,
    required Map<String, String> config,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async {
    final key = [
      executable,
      server.host,
      '${server.port}',
      server.user ?? '',
      ...[
        for (final MapEntry(:key, :value) in environment.entries) '$key=$value',
      ]..sort(),
    ].join('\u0000');

    var connection = _connections[key];
    if (connection == null || connection.isStopping) {
      connection = _Connection(
        this,
        key,
        server,
        executable: executable,
        environment: environment,
      );
      _connections[key] = connection;
      connection.start(config);
    }

    return connection.hold(onLog: onLog, abortTrigger: abortTrigger);
  }
}

/// A hold on a master that is up, for adding forwards to it.
final class SharedConnection {
  SharedConnection._(this._connection);

  final _Connection _connection;
  bool _isReleased = false;

  /// Adds [forward] to the master, and returns it with what `-O forward`
  /// printed: the port the server picked for a remote forward of port 0.
  /// [onLog] gets the failed connections through it, and the master's
  /// warnings.
  /// Completing [abortTrigger] while `-O forward` runs stops it.
  Future<(ForwardHandle, String)> forward(
    List<String> forward, {
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) =>
      _connection.add(
        forward,
        localPort: localPort,
        onLog: onLog,
        abortTrigger: abortTrigger,
      );

  /// Lets the master stop once no forward uses it.
  void release() {
    if (_isReleased) return;
    _isReleased = true;
    _connection.release();
  }
}

final class _Connection {
  _Connection(
    this._pool,
    this._key,
    this._server, {
    required this.executable,
    required this.environment,
  });

  final ConnectionPool _pool;
  final String _key;
  final SshTarget _server;
  final String executable;
  final Map<String, String> environment;

  final _ready = Completer<void>();
  final _abortStart = Completer<void>();
  Directory? _directory;
  ForwardProcess? _master;

  /// Why the master went down, for the forwards still being added.
  SshException? _dropError;

  /// The onLogs of the holds waiting for the master to start.
  final _waiting = <void Function(SshLog log)?>[];
  final _forwards = <_SharedForward>{};
  final _adding = <String>{};
  final _cancelling = <String, Future<void>>{};
  var _holds = 0;

  /// Failed connections, by channel, until ssh says which forward they were on.
  final _failed = <int, SshLog>{};

  /// No new tunnel may join: the master is stopping, or its start is aborted.
  bool isStopping = false;

  String get _socket => '${_directory!.path}/master';

  void start(Map<String, String> config) {
    _ready.future.ignore();
    unawaited(
      _start(config).then(
        (_) {
          _ready.complete();
          // The last hold may have gone in the instant the login finished.
          _stopIfUnused();
        },
        onError: (Object error, StackTrace stackTrace) {
          isStopping = true;
          _forget();
          _ready.completeError(error, stackTrace);
          _stopped();
        },
      ),
    );
  }

  Future<void> _start(Map<String, String> config) async {
    _directory = _masterDirectory();
    final command = sshCommand(
      _server,
      forward: const [],
      config: config,
      executable: executable,
      masterSocket: _socket,
    );
    logger.info(command.join(' '));

    final master = await notFoundOn127(
      () async => ForwardProcess.attach(
        await startWatched(command, environment: environment),
        readiness: MasterReadiness(),
        describe: () => 'the shared connection to ${_server.host}',
        onLog: (log) {
          for (final onLog in [..._waiting]) {
            reportTo(onLog, log);
          }
        },
        onLineAfterReady: _route,
        abortTrigger: _abortStart.future,
      ),
    );
    _master = master;
    unawaited(master.done.then((_) {}, onError: _dropped));
  }

  Future<SharedConnection> hold({
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async {
    _holds++;
    _waiting.add(onLog);
    final aborted = Completer<void>();
    unawaited(
      abortTrigger?.then(
        (_) {
          if (!aborted.isCompleted) {
            aborted.completeError(const SshTunnelAbortedException());
          }
        },
        onError: (Object _) {},
      ),
    );

    try {
      await Future.any([_ready.future, aborted.future]);
      return SharedConnection._(this);
    } catch (exception) {
      release();
      rethrow;
    } finally {
      _waiting.remove(onLog);
    }
  }

  void release() {
    _holds--;
    _stopIfUnused();
  }

  Future<(ForwardHandle, String)> add(
    List<String> forward, {
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async {
    final spec = forward.join(' ');
    // Reopening a forward waits for its cancel, or the cancel closes it too.
    await _cancelling[spec];
    // The master answers a forward it already has with success, and one
    // cancel would then close it for both tunnels.
    if (_adding.contains(spec) || _forwards.any((each) => each.spec == spec)) {
      throw SshTunnelException(
        'another tunnel on this connection already forwards ${forward.last}',
      );
    }
    if (_dropError case final error?) throw error;

    _adding.add(spec);
    try {
      final ({int exitCode, String stdout, String stderr})? result;
      try {
        result = await _run(
          'forward',
          forward,
          timeout: _pool.forwardTimeout,
          abortTrigger: abortTrigger,
        );
      } on SshTunnelAbortedException {
        _retire(forward);
        rethrow;
      }
      if (_dropError case final error?) throw error;
      if (result == null) {
        _retire(forward);
        throw const SshTunnelException(
          'the shared connection did not answer',
        );
      }
      if (result.exitCode != 0) {
        throw tunnelFailure(
          const LineSplitter().convert(result.stderr),
          result.exitCode,
        );
      }

      final shared = _SharedForward(
        this,
        forward,
        spec: spec,
        localPort: localPort,
        onLog: onLog,
      );
      _forwards.add(shared);
      logger.info('Tunnel ready on the shared connection: $spec');
      return (shared, result.stdout.trim());
    } finally {
      _adding.remove(spec);
    }
  }

  Future<void> remove(_SharedForward forward) async {
    if (!_forwards.remove(forward)) return;

    if (_master != null && _dropError == null) {
      final cancel = _cancel(forward);
      _cancelling[forward.spec] = cancel;
      try {
        await cancel;
      } finally {
        unawaited(_cancelling.remove(forward.spec));
      }
    }
    _stopIfUnused();
  }

  Future<void> _cancel(_SharedForward forward) async {
    String failure;
    try {
      final result = await _run(
        'cancel',
        forward.forward,
        timeout: _pool.cancelTimeout,
      );
      // A cancel that fails still exits 0; only its message says so.
      if (result != null &&
          result.exitCode == 0 &&
          !result.stderr.contains('failed')) {
        return;
      }
      failure = result?.stderr ?? 'no answer';
    } on SshException catch (exception) {
      failure = exception.message;
    }

    logger.warning('Could not cancel ${forward.spec}: $failure');
    // Its port stays open until the master stops; no new tunnel may join it.
    isStopping = true;
    _forget();
  }

  /// After a `-O forward` that never answered, which the master may still
  /// have added: no new tunnel may join, and the forward goes if it can.
  void _retire(List<String> forward) {
    isStopping = true;
    _forget();
    unawaited(
      _run('cancel', forward, timeout: _pool.cancelTimeout)
          .then((_) {}, onError: (Object _) {}),
    );
  }

  /// Lets the next tunnel start a new master, unless one already has.
  void _forget() {
    if (_pool._connections[_key] == this) _pool._connections.remove(_key);
  }

  /// Stops the master, or its login, once nothing holds it.
  void _stopIfUnused() {
    if (_holds > 0 || _forwards.isNotEmpty) return;

    isStopping = true;
    _forget();
    final master = _master;
    if (master == null) {
      if (!_abortStart.isCompleted) _abortStart.complete();
      return;
    }
    unawaited(master.close().whenComplete(_stopped));
  }

  /// Every forward fails with why the master went down.
  void _dropped(Object error) {
    _dropError =
        error is SshException ? error : SshException('ssh failed: $error');
    isStopping = true;
    _forget();
    for (final forward in [..._forwards]) {
      forward.fail(error);
    }
    _forwards.clear();
    _stopped();
  }

  void _stopped() {
    try {
      _directory?.deleteSync(recursive: true);
    } on FileSystemException {
      // ssh may still be removing its socket.
    }
  }

  /// Routes a line the master writes once up to the tunnels it is about.
  void _route(String line) {
    if (isMuxChatter(line)) return;

    if (failedChannel(line) case final channel?) {
      _failed[channel] = classify(line);
      return;
    }
    if (freedChannel(line) case (final channel, final port)) {
      final failure = _failed.remove(channel);
      if (failure == null) return;

      final forwards = port == null
          ? const <_SharedForward>[]
          : _forwards.where((forward) => forward.localPort == port).toList();
      // An onLog may close its tunnel, so each loop runs over a copy.
      for (final forward in forwards.isEmpty ? [..._forwards] : forwards) {
        forward.report(failure);
      }
      return;
    }
    if (isProgress(line)) return;

    // A remote forward's own failure goes to the tunnels forwarding there.
    final destination = failedDestination(line);
    final forwards = destination == null
        ? const <_SharedForward>[]
        : _forwards
            .where((forward) => forward.spec.endsWith(':$destination'))
            .toList();
    for (final forward in forwards.isEmpty ? [..._forwards] : forwards) {
      forward.report(classify(line));
    }
  }

  /// `ssh -O` [operation], or null if it didn't finish within [timeout].
  /// Completing [abortTrigger] first stops it with an
  /// [SshTunnelAbortedException].
  Future<({int exitCode, String stdout, String stderr})?> _run(
    String operation,
    List<String> forward, {
    required Duration timeout,
    Future<void>? abortTrigger,
  }) async {
    final command = muxCommand(
      _server,
      operation: operation,
      forward: forward,
      masterSocket: _socket,
      executable: executable,
    );
    logger.info(command.join(' '));

    final Process process;
    try {
      process = await Process.start(
        command.first,
        command.sublist(1),
        environment: environment,
      );
    } on ProcessException {
      throw SshNotFoundException();
    }
    unawaited(process.stdin.close().then((_) {}, onError: (Object _) {}));
    final stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();

    final aborted = Completer<int>();
    unawaited(
      abortTrigger?.then(
        (_) {
          if (!aborted.isCompleted) {
            aborted.completeError(const SshTunnelAbortedException());
          }
        },
        onError: (Object _) {},
      ),
    );

    try {
      final code =
          await Future.any([process.exitCode, aborted.future]).timeout(timeout);
      return (exitCode: code, stdout: await stdout, stderr: await stderr);
    } on TimeoutException {
      process.kill();
      return null;
    } on SshTunnelAbortedException {
      process.kill();
      rethrow;
    }
  }
}

// A socket's path must fit in 104 bytes, with the 17 ssh adds while it
// creates it, and ssh can't take a `$` or `"` in a ControlPath.
final _unsafeInSocketPath = RegExp(r'["$]|[\x00-\x1f]');

/// A directory of the user's alone for a master's socket.
Directory _masterDirectory() {
  final temp = Directory.systemTemp;
  final base =
      temp.path.length <= 60 && !temp.path.contains(_unsafeInSocketPath)
          ? temp
          : Directory('/tmp');
  try {
    return base.createTempSync('ssh');
  } on FileSystemException catch (exception) {
    throw SshException(
      'could not make a directory for the shared connection in '
      '${base.path}: ${exception.message}',
    );
  }
}

final class _SharedForward implements ForwardHandle {
  _SharedForward(
    this._connection,
    this.forward, {
    required this.spec,
    required this.localPort,
    required void Function(SshLog log)? onLog,
  }) : _onLog = onLog {
    // A caller that never listens to done must not crash on a dropped master.
    done.ignore();
  }

  final _Connection _connection;
  final List<String> forward;
  final String spec;

  /// The local port it listens on, to route its failed connections to it.
  final int? localPort;
  final void Function(SshLog log)? _onLog;
  final _done = Completer<void>();
  bool _isClosed = false;

  @override
  Future<void> get done => _done.future;

  void report(SshLog log) {
    if (!_isClosed) reportTo(_onLog, log);
  }

  void fail(Object error) {
    if (!_done.isCompleted) _done.completeError(error);
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    logger.info('Closing tunnel on the shared connection: $spec');
    await _connection.remove(this);
    if (!_done.isCompleted) _done.complete();
  }
}
