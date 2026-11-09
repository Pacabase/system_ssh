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
  Future<(ForwardHandle, String)> forward(
    List<String> forward, {
    int? localPort,
    void Function(SshLog log)? onLog,
  }) =>
      _connection.add(forward, localPort: localPort, onLog: onLog);

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

  /// The onLogs of holds waiting for the master to start.
  final _waiting = <_Waiter>[];
  final _forwards = <_SharedForward>{};
  final _adding = <String>{};
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
        (_) => _ready.complete(),
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
    // A short path: a socket's must fit in 104 bytes, with ssh's 17-byte
    // suffix while it creates it. The directory is the user's alone.
    _directory = Directory.systemTemp.createTempSync('ssh');
    final command = sshCommand(
      _server,
      forward: const [],
      config: config,
      executable: executable,
      masterSocket: _socket,
    );
    logger.info(command.join(' '));

    try {
      final master = await ForwardProcess.attach(
        await startWatched(command, environment: environment),
        readiness: MasterReadiness(),
        describe: () => 'the shared connection to ${_server.host}',
        onLog: (log) {
          for (final waiter in [..._waiting]) {
            _report(waiter.onLog, log);
          }
        },
        onLineAfterReady: _route,
        abortTrigger: _abortStart.future,
      );
      _master = master;
      unawaited(master.done.then((_) {}, onError: _dropped));
    } on SshTunnelException catch (exception) {
      // sh's code for a missing command; Windows fails to start instead.
      if (exception.exitCode == 127) throw SshNotFoundException();
      rethrow;
    }
  }

  Future<SharedConnection> hold({
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async {
    _holds++;
    final waiter = _Waiter(onLog);
    _waiting.add(waiter);

    final aborted = Completer<void>();
    unawaited(
      abortTrigger?.then(
        (_) {
          if (_ready.isCompleted || aborted.isCompleted) return;
          aborted.completeError(const SshTunnelAbortedException());
          _waiting.remove(waiter);
          // Only the last tunnel waiting may stop the login.
          if (_waiting.isEmpty) {
            isStopping = true;
            _forget();
            if (!_abortStart.isCompleted) _abortStart.complete();
          }
        },
        onError: (Object _) {},
      ),
    );

    try {
      await Future.any([_ready.future, aborted.future]);
    } catch (exception) {
      _waiting.remove(waiter);
      release();
      rethrow;
    }

    _waiting.remove(waiter);
    return SharedConnection._(this);
  }

  void release() {
    _holds--;
    _stopIfUnused();
  }

  Future<(ForwardHandle, String)> add(
    List<String> forward, {
    int? localPort,
    void Function(SshLog log)? onLog,
  }) async {
    final spec = forward.join(' ');
    // The master answers a forward it already has with success, and one
    // cancel would then close it for both tunnels.
    if (_adding.contains(spec) || _forwards.any((each) => each.spec == spec)) {
      throw SshTunnelException(
        'another tunnel on this connection already forwards ${forward.last}',
      );
    }

    _adding.add(spec);
    try {
      final result = await _run('forward', forward);
      if (result.exitCode != 0) {
        final lines = const LineSplitter().convert(result.stderr);
        final reason = failureMessage(lines);
        throw SshTunnelException(
          reason.isEmpty ? 'ssh exited with code ${result.exitCode}' : reason,
          log: lines,
          exitCode: result.exitCode,
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

    if (_master != null && !isStopping) {
      final result = await _run('cancel', forward.forward);
      // A cancel that fails still exits 0; only its message says so.
      if (result.exitCode != 0 || result.stderr.contains('failed')) {
        logger.warning('Could not cancel ${forward.spec}: ${result.stderr}');
        if (_forwards.isNotEmpty) {
          // Its port stays open until the master stops; none must reuse it.
          isStopping = true;
          _forget();
        }
      }
    }
    _stopIfUnused();
  }

  /// Lets the next tunnel start a new master, unless one already has.
  void _forget() {
    if (_pool._connections[_key] == this) _pool._connections.remove(_key);
  }

  void _stopIfUnused() {
    final master = _master;
    if (master == null || _holds > 0 || _forwards.isNotEmpty) return;

    isStopping = true;
    _forget();
    unawaited(master.close().whenComplete(_stopped));
  }

  /// Every forward fails with why the master went down.
  void _dropped(Object error) {
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

      final forwards =
          _forwards.where((forward) => forward.localPort == port).toList();
      for (final forward in forwards.isEmpty ? _forwards : forwards) {
        forward.report(failure);
      }
      return;
    }
    if (isProgress(line)) return;

    for (final forward in [..._forwards]) {
      forward.report(classify(line));
    }
  }

  Future<({int exitCode, String stdout, String stderr})> _run(
    String operation,
    List<String> forward,
  ) async {
    final command = muxCommand(
      _server,
      operation: operation,
      forward: forward,
      masterSocket: _socket,
      executable: executable,
    );
    logger.info(command.join(' '));

    try {
      final result = await Process.run(
        command.first,
        command.sublist(1),
        environment: environment,
      );
      return (
        exitCode: result.exitCode,
        stdout: '${result.stdout}',
        stderr: '${result.stderr}',
      );
    } on ProcessException {
      throw SshNotFoundException();
    }
  }
}

final class _Waiter {
  _Waiter(this.onLog);

  final void Function(SshLog log)? onLog;
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
    if (!_isClosed) _report(_onLog, log);
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

void _report(void Function(SshLog log)? onLog, SshLog log) {
  try {
    onLog?.call(log);
  } catch (exception, stackTrace) {
    logger.warning('onLog threw', exception, stackTrace);
  }
}
