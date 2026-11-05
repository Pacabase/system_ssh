import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:system_ssh/src/system_ssh_tunnel.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fakes.dart';

void main() {
  const localPort = 50000;
  const connectingLine = 'debug1: Connecting to ssh.example.com';
  const listeningLine =
      'debug1: Local forwarding listening on 127.0.0.1 port $localPort.';
  const sessionLine = 'debug1: Entering interactive session.';
  const ready = ['err:$listeningLine', 'err:$sessionLine'];

  Future<void> ended(SshTunnel tunnel) =>
      tunnel.done.then((_) {}, onError: (Object _) {});

  Matcher throwsTunnelException(
    String message, {
    Object? log = anything,
    int exitCode = 255,
    bool isPermanent = false,
  }) =>
      throwsA(
        isA<SshTunnelException>()
            .having((exception) => exception.message, 'message', message)
            .having((exception) => exception.log, 'log', log)
            .having((exception) => exception.exitCode, 'exitCode', exitCode)
            .having(
              (exception) => exception.isPermanent,
              'isPermanent',
              isPermanent,
            ),
      );

  group('attach', () {
    test('says a refused login is permanent', () async {
      const denied = 'user@ssh.example.com: Permission denied (publickey).';
      final process = await startFake(['err:$denied', 'exit:255']);

      await expectLater(
        SystemSshTunnel.attach(process, localPort: localPort),
        throwsTunnelException(denied, isPermanent: true),
      );
    });

    test('returns a tunnel once ssh reports the forward listening', () async {
      final process = await startFake([
        'err:$connectingLine',
        ...ready,
        'hang',
      ]);

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
      );

      expect(tunnel.localPort, localPort);
    });

    test(
      'keeps waiting while ssh runs without reporting the forward',
      () async {
        final process = await startFake([
          'err:$connectingLine',
          'sleep:200',
          ...ready,
          'hang',
        ]);

        final tunnel = await SystemSshTunnel.attach(
          process,
          localPort: localPort,
        );

        expect(tunnel.localPort, localPort);
      },
    );

    for (final (listening, waitingFor) in [
      (50001, 50000),
      (500001, 50000),
      (50000, 5000),
    ]) {
      test('ignores port $listening while waiting for $waitingFor', () async {
        final line =
            'debug1: Local forwarding listening on 127.0.0.1 port $listening.';
        final process = await startFake([
          'err:$line',
          'err:$sessionLine',
          'exit:255',
        ]);

        await expectLater(
          SystemSshTunnel.attach(process, localPort: waitingFor),
          throwsTunnelException('$line\n$sessionLine'),
        );
      });
    }

    test('is not ready on the listening line alone', () async {
      final process = await startFake(['err:$listeningLine', 'exit:255']);

      await expectLater(
        SystemSshTunnel.attach(process, localPort: localPort),
        throwsTunnelException(listeningLine),
      );
    });

    test('is not ready on a session that starts before the listener', () async {
      final process = await startFake([
        'err:$sessionLine',
        'err:$listeningLine',
        'exit:255',
      ]);

      await expectLater(
        SystemSshTunnel.attach(process, localPort: localPort),
        throwsA(isA<SshTunnelException>()),
      );
    });

    test('throws when ssh logs the listener but cannot bind it', () async {
      final process = await startFake([
        'err:$listeningLine',
        'err:bind [127.0.0.1]:$localPort: Address already in use',
        'err:channel_setup_fwd_listener_tcpip: cannot listen to port: $localPort',
        'err:Could not request local forwarding.',
        'exit:255',
      ]);

      await expectLater(
        SystemSshTunnel.attach(process, localPort: localPort),
        throwsTunnelException(
          'bind [127.0.0.1]:$localPort: Address already in use\n'
          'channel_setup_fwd_listener_tcpip: cannot listen to port: $localPort\n'
          'Could not request local forwarding.',
        ),
      );
    });

    test(
      'throws with the reason, the log and the exit code when ssh exits',
      () async {
        const refused =
            'ssh: connect to host ssh.example.com port 22: Connection refused';
        final process = await startFake([
          'err:OpenSSH_9.6p1, LibreSSL 3.3.6',
          'err:$connectingLine',
          'err:$refused',
          'exit:255',
        ]);

        await expectLater(
          SystemSshTunnel.attach(process, localPort: localPort),
          throwsTunnelException(
            refused,
            log: ['OpenSSH_9.6p1, LibreSSL 3.3.6', connectingLine, refused],
          ),
        );
      },
    );

    test('names the exit code when ssh exits silently', () async {
      final process = await startFake(['exit:3']);

      await expectLater(
        SystemSshTunnel.attach(process, localPort: localPort),
        throwsTunnelException(
          'ssh exited with code 3',
          log: isEmpty,
          exitCode: 3,
        ),
      );
    });

    test('keeps the last lines even when they land after the exit', () async {
      final process = await startFake([
        'late:Host key verification failed.',
        'exit:255',
      ]);

      await expectLater(
        SystemSshTunnel.attach(process, localPort: localPort),
        throwsTunnelException(
          'Host key verification failed.',
          isPermanent: true,
        ),
      );
    });

    test('gives up on stderr that stays open after ssh exits', () async {
      final process = await startFake([
        'hold',
        'err:ssh: connect to host ssh.example.com port 22: Connection refused',
        'exit:255',
      ]);

      await expectLater(
        SystemSshTunnel.attach(
          process,
          localPort: localPort,
        ).timeout(const Duration(seconds: 3)),
        throwsTunnelException(
          'ssh: connect to host ssh.example.com port 22: Connection refused',
        ),
      );
    });

    test('passes onLog every line while connecting, and warnings after',
        () async {
      const refused =
          'channel 3: open failed: connect failed: Connection refused';
      final process = await startFake([
        'err:$connectingLine',
        ...ready,
        'err:debug1: channel 0: new [port listener]',
        'err:$refused',
        'err:',
        'exit:0',
      ]);
      final lines = <String>[];

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
        onLog: lines.add,
      );
      await exitCodeOf(process);
      await ended(tunnel);

      expect(lines, [connectingLine, listeningLine, sessionLine, refused]);
    });

    test('passes onRefused why each forwarded connection was refused',
        () async {
      final process = await startFake([
        'err:channel 9: open failed: connect failed: Too early',
        ...ready,
        'err:channel 3: open failed: connect failed: Connection refused',
        'err:debug1: channel 4: new [direct-tcpip]',
        'err:channel 4: open failed: administratively prohibited: open failed',
        'exit:0',
      ]);
      final reasons = <String>[];

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
        onRefused: reasons.add,
      );
      await exitCodeOf(process);
      await ended(tunnel);

      expect(reasons, ['Connection refused', 'administratively prohibited']);
    });

    test('passes onLog nothing ssh says after close', () async {
      final process = _GoodbyeProcess([listeningLine, sessionLine]);
      final lines = <String>[];
      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
        onLog: lines.add,
      );

      await tunnel.close();

      expect(lines, [listeningLine, sessionLine]);
    });

    test('drains stdout so a chatty ssh never blocks', () async {
      final process = await startFake(['out:1000000', ...ready, 'hang']);

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
      ).timeout(const Duration(seconds: 10));

      expect(tunnel.localPort, localPort);
    });
  });

  group('abortTrigger', () {
    test('throws and kills ssh when completed while connecting', () async {
      final process = await startFake(['err:$connectingLine', 'hang']);
      final abort = Completer<void>();

      final attaching = SystemSshTunnel.attach(
        process,
        localPort: localPort,
        onLog: (_) => abort.complete(),
        abortTrigger: abort.future,
      );

      await expectLater(attaching, throwsA(isA<SshTunnelAbortedException>()));
      expect(await exitCodeOf(process), terminated);
    });

    test('throws and kills ssh when already completed', () async {
      final process = await startFake(['hang']);

      await expectLater(
        SystemSshTunnel.attach(
          process,
          localPort: localPort,
          abortTrigger: Future.value(),
        ),
        throwsA(isA<SshTunnelAbortedException>()),
      );
      expect(await exitCodeOf(process), terminated);
    });

    test('is ignored when it fails', () async {
      final process = await startFake([...ready, 'hang']);

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
        abortTrigger: Future.error(StateError('ignored')),
      );

      expect(tunnel.localPort, localPort);
    });

    test('leaves a ready tunnel running when completed afterwards', () async {
      final process = await startFake([...ready, 'hang']);
      final abort = Completer<void>();
      var hasExited = false;
      unawaited(process.exitCode.then((_) => hasExited = true));

      await SystemSshTunnel.attach(
        process,
        localPort: localPort,
        abortTrigger: abort.future,
      );
      abort.complete();

      expect(isRunning(process.pid), isTrue);
      expect(hasExited, isFalse);
    });
  });

  group('done', () {
    test('says a refused login is permanent', () async {
      const denied = 'Received disconnect from 10.0.0.1 port 22:2: '
          'Too many authentication failures';
      final process = await startFake([...ready, 'err:$denied', 'exit:255']);

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
      );

      await expectLater(
        tunnel.done.timeout(const Duration(seconds: 10)),
        throwsTunnelException(denied, isPermanent: true),
      );
    });

    test('fails with ssh\'s reason when the connection drops', () async {
      const closed = 'Connection to ssh.example.com closed by remote host.';
      final process = await startFake([
        ...ready,
        'err:debug1: channel 0: new [port listener]',
        'err:$closed',
        'exit:255',
      ]);

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
      );

      await expectLater(
        tunnel.done.timeout(const Duration(seconds: 10)),
        throwsTunnelException(
          closed,
          log: ['debug1: channel 0: new [port listener]', closed],
        ),
      );
    });

    test('names the exit code when ssh drops without a reason', () async {
      final process = await startFake([...ready, 'exit:255']);

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
      );

      await expectLater(
        tunnel.done.timeout(const Duration(seconds: 10)),
        throwsTunnelException('ssh exited with code 255', log: isEmpty),
      );
    });

    test('keeps only ssh\'s last lines after the tunnel is up', () async {
      final process = await startFake([
        ...ready,
        for (var line = 1; line <= 30; line++) 'err:debug1: line $line',
        'exit:255',
      ]);

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
      );

      await expectLater(
        tunnel.done.timeout(const Duration(seconds: 10)),
        throwsA(
          isA<SshTunnelException>().having(
            (exception) => exception.log,
            'log',
            [for (var line = 11; line <= 30; line++) 'debug1: line $line'],
          ),
        ),
      );
    });

    test('does not crash a caller that never listens to it', () async {
      final process = await startFake([...ready, 'exit:255']);

      await SystemSshTunnel.attach(process, localPort: localPort);
      await exitCodeOf(process);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });

    test('completes after close', () async {
      final process = await startFake([...ready, 'hang']);
      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
      );

      await tunnel.close();

      await expectLater(
        tunnel.done.timeout(const Duration(seconds: 10)),
        completes,
      );
    });
  });

  group('close', () {
    late Process process;
    late SystemSshTunnel tunnel;

    setUp(() async {
      process = await startFake([...ready, 'hang']);
      tunnel = await SystemSshTunnel.attach(process, localPort: localPort);
    });

    test('terminates ssh', () async {
      await tunnel.close();

      expect(await exitCodeOf(process), terminated);
    });

    test('waits for ssh to exit', () async {
      var hasExited = false;
      unawaited(process.exitCode.then((_) => hasExited = true));

      await tunnel.close();

      expect(hasExited, isTrue);
    });

    test('is idempotent', () async {
      await tunnel.close();
      await tunnel.close();

      expect(await exitCodeOf(process), terminated);
    });
  });

  test('close does not kill an ssh that already exited', () async {
    final process = _KillCounting(await startFake([...ready, 'exit:0']));
    final tunnel = await SystemSshTunnel.attach(process, localPort: localPort);
    await ended(tunnel).timeout(const Duration(seconds: 10));

    await tunnel.close();

    expect(process.kills, 0);
    expect(await exitCodeOf(process), 0);
  });

  test('close kills a running ssh once', () async {
    final process = _KillCounting(await startFake([...ready, 'hang']));
    final tunnel = await SystemSshTunnel.attach(process, localPort: localPort);

    await tunnel.close();
    await tunnel.close();

    expect(process.kills, 1);
  });

  group('logging', () {
    late List<LogRecord> records;

    setUp(() {
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = level);
      records = [];
      final subscription = Logger.root.onRecord
          .where((record) => record.loggerName == 'system_ssh')
          .listen(records.add);
      addTearDown(subscription.cancel);
    });

    test('logs every stderr line at FINE, even after the tunnel is up',
        () async {
      final process = await startFake([
        'err:$connectingLine',
        ...ready,
        'err:debug1: channel 0: new [port listener]',
        'exit:0',
      ]);

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
      );
      await ended(tunnel).timeout(const Duration(seconds: 10));

      expect(
        records
            .where((record) => record.level == Level.FINE)
            .map((record) => record.message),
        [
          connectingLine,
          listeningLine,
          sessionLine,
          'debug1: channel 0: new [port listener]',
        ],
      );
    });

    test('survives an onLog that throws, and logs it at WARNING', () async {
      final process =
          await startFake(['err:$connectingLine', ...ready, 'hang']);
      var calls = 0;

      final tunnel = await SystemSshTunnel.attach(
        process,
        localPort: localPort,
        onLog: (_) {
          calls++;
          throw StateError('onLog failed');
        },
      );

      expect(tunnel.localPort, localPort);
      expect(calls, 3);
      expect(
        records.where((record) => record.level == Level.WARNING),
        everyElement(
          isA<LogRecord>()
              .having((record) => record.message, 'message', 'onLog threw')
              .having((record) => record.error, 'error', isA<StateError>()),
        ),
      );
      expect(
        records.where((record) => record.level == Level.WARNING),
        hasLength(3),
      );
    });
  });
}

/// A [Process] that counts its [kill] calls.
final class _KillCounting implements Process {
  _KillCounting(this._process);

  final Process _process;
  int kills = 0;

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
    kills++;
    return _process.kill(signal);
  }
}

// An ssh that, like the real one, says "Killed by signal 15." as it is killed.
class _GoodbyeProcess implements Process {
  _GoodbyeProcess(List<String> lines) {
    lines.forEach(_stderr.add);
  }

  final _stderr = StreamController<String>();
  final _exitCode = Completer<int>();

  @override
  Stream<List<int>> get stderr =>
      _stderr.stream.map((line) => '$line\n'.codeUnits);

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  int get pid => 0;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _stderr.add('Killed by signal 15.');
    unawaited(_stderr.close());
    _exitCode.complete(255);
    return true;
  }
}
