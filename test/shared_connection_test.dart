// Windows' OpenSSH can't share a connection, so the pool never runs there.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/shared_connection.dart';
import 'package:system_ssh/src/ssh_output.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';
import 'fakes/fakes.dart';

void main() {
  const server = SshTarget('ssh.example.com');
  const sessionLine = 'debug1: Entering interactive session.';
  late FakeSsh fake;
  late ConnectionPool pool;

  setUp(() async {
    fake = await FakeSsh.create();
    pool = ConnectionPool(
      forwardTimeout: const Duration(seconds: 1),
      cancelTimeout: const Duration(milliseconds: 300),
    );
  });

  Future<SshTunnel> open({
    int? localPort,
    CountingPorts? ports,
    Future<bool> Function(int port) portIsFree = isPortFree,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async {
    final tunnel = await openSystemForward(
      server,
      forward: localForwardTo('db.example.com', 3306),
      localPort: localPort,
      freePort: (ports ?? CountingPorts()).next,
      portIsFree: portIsFree,
      onLog: onLog,
      abortTrigger: abortTrigger,
      executable: fake.path,
      pool: pool,
    );
    addTearDown(tunnel.close);
    return tunnel;
  }

  Future<SshRemoteTunnel> openRemote({
    int? remotePort,
    Future<void>? abortTrigger,
  }) async {
    final tunnel = await openSystemRemoteForward(
      server,
      localHost: 'localhost',
      localPort: 3000,
      remotePort: remotePort,
      abortTrigger: abortTrigger,
      executable: fake.path,
      pool: pool,
    );
    addTearDown(tunnel.close);
    return tunnel;
  }

  List<String> operations() => [
        for (final command in fake.muxCommands)
          [
            command[command.indexOf('-O') + 1],
            command[command.indexOf('-O') + 3],
          ].join(' '),
      ];

  String forwardOf(SshTunnel tunnel) =>
      'forward 127.0.0.1:${tunnel.localPort}:db.example.com:3306';

  /// The directory of master [attempt]'s socket.
  Directory socketDirectory([int attempt = 1]) {
    final option = fake.attempts[attempt - 1]
        .firstWhere((argument) => argument.startsWith('ControlPath='));
    final socket = option.substring('ControlPath="'.length, option.length - 1);
    return File(socket).parent;
  }

  /// Has a `held` master finish logging in.
  void logIn() => fake
    ..masterSays('debug1: setting up multiplex master socket')
    ..masterSays(sessionLine);

  /// What a master writes when a connection to [port] couldn't be forwarded.
  void failConnection(int channel, {int? port}) => fake
    ..masterSays(
      'channel $channel: open failed: connect failed: Connection refused',
    )
    ..masterSays(
      port == null
          ? 'debug1: channel $channel: free: direct-tcpip, nchannels 4'
          : 'debug1: channel $channel: free: direct-tcpip: listening port '
              '$port for db.example.com port 3306, connect from 127.0.0.1 '
              'port 50123 to 127.0.0.1 port $port, nchannels 4',
    );

  const refused = SshForwardFailed(
    'channel 3: open failed: connect failed: Connection refused',
    reason: 'Connection refused',
  );

  test('two tunnels share one master', () async {
    fake.attemptModes([AttemptMode.ready]);

    final first = await open();
    final second = await open();

    expect(fake.attempts, hasLength(1));
    expect(
      fake.attempts.single,
      containsAll(['ControlMaster=yes', 'ControlPersist=no']),
    );
    expect(fake.attempts.single, isNot(contains('-L')));
    expect(operations(), [forwardOf(first), forwardOf(second)]);
  });

  test("runs -O commands without the user's config or ControlMaster", () async {
    fake.attemptModes([AttemptMode.ready]);

    await open();

    final controlPath = fake.attempts.single
        .firstWhere((argument) => argument.startsWith('ControlPath='));
    final command = fake.muxCommands.single;
    expect(command.sublist(0, 2), ['-F', 'none']);
    expect(
      command,
      containsAll(['ControlMaster=no', controlPath, 'BatchMode=yes']),
    );
  });

  test('says a taken fixed port is in use before logging in', () async {
    await expectLater(
      open(localPort: 50000, portIsFree: (_) async => false),
      throwsA(isA<SshPortInUseException>()),
    );
    expect(fake.attempts, isEmpty);
  });

  test('finishes closing when ssh -O cancel cannot run', () async {
    fake.attemptModes([AttemptMode.ready]);
    final tunnel = await open();
    final master = fake.attemptPid(1)!;

    File(fake.path).deleteSync();
    await tunnel.close();

    await expectLater(tunnel.done, completes);
    expect(await stops(master), isTrue);
  });

  test('retires a master whose -O forward never answers', () async {
    fake
      ..attemptModes([AttemptMode.ready])
      ..muxModes(['hang', 'ok']);

    await expectLater(
      open(localPort: await pickFreePort()),
      throwsA(
        isA<SshTunnelException>().having(
          (exception) => exception.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
    await eventually(() => operations().length == 2 ? true : null);
    expect(operations().last, startsWith('cancel '));

    await open();
    expect(fake.attempts, hasLength(2));
  });

  test('closing one tunnel cancels its forward and keeps the master', () async {
    fake.attemptModes([AttemptMode.ready]);
    final first = await open();
    await open();

    await first.close();
    await first.close();
    await open();

    expect(fake.attempts, hasLength(1));
    expect(
      operations().where((operation) => operation.startsWith('cancel')),
      ['cancel 127.0.0.1:${first.localPort}:db.example.com:3306'],
    );
  });

  test('the last close stops the master and removes its directory', () async {
    fake.attemptModes([AttemptMode.ready]);
    final first = await open();
    final second = await open();

    await first.close();
    await second.close();

    expect(await stops(fake.attemptPid(1)!), isTrue);
    await eventually(() => socketDirectory().existsSync() ? null : true);
    await expectLater(first.done, completes);

    await open();
    expect(fake.attempts, hasLength(2));
  });

  test('a tunnel opened as the last one closes still gets a master', () async {
    fake.attemptModes([AttemptMode.ready]);
    final first = await open();

    final (_, second) = await (first.close(), open()).wait;

    expect(operations().last, forwardOf(second));
    final pid = fake.attemptPid(fake.attempts.length)!;
    expect(isRunning(pid), isTrue);
    if (fake.attempts.length == 2) {
      expect(await stops(fake.attemptPid(1)!), isTrue);
    }
  });

  test('tunnels opened together wait on one login', () async {
    fake.attemptModes([AttemptMode.ready]);

    final tunnels = await Future.wait([open(), open(), open()]);

    expect(fake.attempts, hasLength(1));
    expect(operations().toSet(), tunnels.map(forwardOf).toSet());
  });

  test('passes the login to the onLog of each tunnel waiting on it', () async {
    fake.attemptModes([AttemptMode.held]);
    final firstLogs = <SshLog>[];
    final secondLogs = <SshLog>[];

    final opening = Future.wait([
      open(onLog: firstLogs.add),
      open(onLog: secondLogs.add),
    ]);
    await eventually(() => fake.attemptPid(1));
    logIn();
    await opening;

    expect(firstLogs, contains(const SshProgress(sessionLine)));
    expect(secondLogs, contains(const SshProgress(sessionLine)));
  });

  test('a failed login fails every tunnel waiting on it, once', () async {
    fake.attemptModes([AttemptMode.fail, AttemptMode.ready]);
    final failure = throwsA(
      isA<SshTunnelException>().having(
        (exception) => exception.message,
        'message',
        contains('Connection refused'),
      ),
    );

    await Future.wait([
      expectLater(open(), failure),
      expectLater(open(), failure),
    ]);
    expect(fake.attempts, hasLength(1));

    await open();
    expect(fake.attempts, hasLength(2));
  });

  test('retries a taken port on the same login', () async {
    fake
      ..attemptModes([AttemptMode.ready])
      ..muxModes(['fail', 'ok']);
    var checks = 0;

    final tunnel = await open(portIsFree: (_) async => ++checks > 1);

    expect(fake.attempts, hasLength(1));
    expect(operations(), hasLength(2));
    expect(operations().last, forwardOf(tunnel));
  });

  test('says a fixed local port the master could not bind is in use', () async {
    fake
      ..attemptModes([AttemptMode.ready])
      ..muxModes(['fail']);
    var checks = 0;

    await expectLater(
      open(localPort: 50000, portIsFree: (_) async => checks++ == 0),
      throwsA(isA<SshPortInUseException>()),
    );
    expect(await stops(fake.attemptPid(1)!), isTrue);
  });

  test('a remote tunnel gets the port the server picked', () async {
    fake.attemptModes([AttemptMode.ready]);

    final tunnel = await openRemote();

    expect(tunnel.remotePort, 41234);
    expect(operations(), ['forward 127.0.0.1:0:localhost:3000']);
  });

  test('cancels a remote forward whose picked port ssh never printed',
      () async {
    fake
      ..attemptModes([AttemptMode.ready])
      ..muxModes(['quiet', 'ok']);

    await expectLater(openRemote(), throwsA(isA<SshException>()));
    expect(operations(), [
      'forward 127.0.0.1:0:localhost:3000',
      'cancel 127.0.0.1:0:localhost:3000',
    ]);
  });

  test('refuses a second tunnel with the same remote forward', () async {
    fake.attemptModes([AttemptMode.ready]);
    await openRemote(remotePort: 8080);

    await expectLater(
      openRemote(remotePort: 8080),
      throwsA(
        isA<SshTunnelException>().having(
          (exception) => exception.message,
          'message',
          contains('already forwards'),
        ),
      ),
    );
    expect(operations(), hasLength(1));
  });

  test('reopens a remote forward only once its cancel is done', () async {
    fake
      ..attemptModes([AttemptMode.ready])
      ..muxModes(['ok', 'ok', 'slow', 'ok']);
    final first = await openRemote(remotePort: 8080);
    await openRemote(remotePort: 9090);

    final closing = first.close();
    final reopening = openRemote(remotePort: 8080);
    await eventually(() => operations().length == 3 ? true : null);
    // The cancel takes 300 ms; the forward must not start before it ends.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(operations(), hasLength(3));
    await closing;
    final second = await reopening;

    expect(second.remotePort, 8080);
    expect(operations().skip(2), [
      'cancel 127.0.0.1:8080:localhost:3000',
      'forward 127.0.0.1:8080:localhost:3000',
    ]);
  });

  group('a dropped master', () {
    test('fails every tunnel on it, and sends no cancels', () async {
      fake.attemptModes([AttemptMode.ready]);
      final first = await open();
      final second = await open();

      Process.killPid(fake.attemptPid(1)!, ProcessSignal.sigkill);

      await expectLater(first.done, throwsA(isA<SshTunnelException>()));
      await expectLater(second.done, throwsA(isA<SshTunnelException>()));
      await first.close();
      await second.close();
      expect(operations(), hasLength(2));
      expect(socketDirectory().existsSync(), isFalse);

      await open();
      expect(fake.attempts, hasLength(2));
    });

    test('fails a forward added after it with its reason', () async {
      fake.attemptModes([AttemptMode.ready]);
      final first = await open();
      final shared = await pool.connect(
        server,
        executable: fake.path,
        environment: const {},
        config: const {},
      );
      addTearDown(shared.release);

      Process.killPid(fake.attemptPid(1)!, ProcessSignal.sigkill);
      final reason = await first.done.then<Object>(
        (_) => fail('done completed'),
        onError: (Object error) => error,
      );

      await expectLater(
        shared.forward(['-L', '127.0.0.1:50001:db.example.com:3306']),
        throwsA(same(reason)),
      );
    });
  });

  group('routes', () {
    test("a failed connection to its own tunnel's onLog", () async {
      fake.attemptModes([AttemptMode.ready]);
      final firstLogs = <SshLog>[];
      final secondLogs = <SshLog>[];
      final first = await open(onLog: firstLogs.add);
      await open(onLog: secondLogs.add);
      firstLogs.clear();
      secondLogs.clear();

      fake.masterSays(
        'mux_master_process_open_fwd: requested local forward '
        '127.0.0.1:1 -> db.example.com:3306 failed',
      );
      failConnection(3, port: first.localPort);
      fake.masterSays('Warning: the server says hello');
      await eventually(() => secondLogs.isEmpty ? null : true);

      expect(firstLogs, [
        refused,
        const SshMessage('Warning: the server says hello'),
      ]);
      expect(secondLogs, [const SshMessage('Warning: the server says hello')]);
    });

    test('a failed connection that names no port to every tunnel', () async {
      fake.attemptModes([AttemptMode.ready]);
      final firstLogs = <SshLog>[];
      final secondLogs = <SshLog>[];
      await open(onLog: firstLogs.add);
      await openRemote(remotePort: 8080);
      await open(onLog: secondLogs.add);
      firstLogs.clear();
      secondLogs.clear();

      failConnection(3);
      await eventually(() => secondLogs.isEmpty ? null : true);

      expect(firstLogs, [refused]);
      expect(secondLogs, [refused]);
    });

    test("a remote forward's failed destination to that tunnel only", () async {
      fake.attemptModes([AttemptMode.ready]);
      final localLogs = <SshLog>[];
      final remoteLogs = <SshLog>[];
      await open(onLog: localLogs.add);
      await openSystemRemoteForward(
        server,
        localHost: 'localhost',
        localPort: 3000,
        remotePort: 8080,
        onLog: remoteLogs.add,
        executable: fake.path,
        pool: pool,
      ).then((tunnel) => addTearDown(tunnel.close));
      localLogs.clear();
      remoteLogs.clear();

      fake
        ..masterSays('bind [127.0.0.1]:50000: Address already in use')
        ..masterSays('connect_to localhost port 3000: failed.')
        ..masterSays('Warning: the server says hello');
      await eventually(() => localLogs.isEmpty ? null : true);

      expect(remoteLogs, [
        const SshMessage('connect_to localhost port 3000: failed.'),
        const SshMessage('Warning: the server says hello'),
      ]);
      expect(localLogs, [const SshMessage('Warning: the server says hello')]);
    });

    test('reads the port from a socket forward that ssh freed', () {
      expect(
        freedChannel(
          'debug1: channel 3: free: direct-streamlocal@openssh.com: '
          'listening port 41234 for /var/run/docker.sock port 0, connect '
          'from 127.0.0.1 port 50123 to 127.0.0.1 port 41234, nchannels 4',
        ),
        (3, 41234),
      );
    });

    test('past an onLog that throws or closes its own tunnel', () async {
      fake.attemptModes([AttemptMode.ready]);
      final logs = <SshLog>[];
      late SshTunnel first;
      first = await open(
        onLog: (log) {
          if (log is SshForwardFailed) unawaited(first.close());
        },
      );
      await open(onLog: (_) => throw StateError('onLog broke'));
      await open(onLog: logs.add);
      logs.clear();

      failConnection(3);
      await eventually(() => logs.isEmpty ? null : true);

      expect(logs, [refused]);
    });
  });

  group('a cancel that fails', () {
    for (final mode in ['silent-fail', 'fail', 'hang']) {
      test('($mode) moves new tunnels to a new master', () async {
        fake
          ..attemptModes([AttemptMode.ready])
          ..muxModes(['ok', 'ok', mode, 'ok']);
        final first = await open();
        final second = await open();

        await first.close();
        await open();

        expect(fake.attempts, hasLength(2));
        expect(isRunning(fake.attemptPid(1)!), isTrue);
        await second.close();
        expect(await stops(fake.attemptPid(1)!), isTrue);
      });
    }
  });

  group('aborting', () {
    test('the only tunnel waiting stops the login', () async {
      fake.attemptModes([AttemptMode.held]);
      final abort = Completer<void>();

      final opening = open(abortTrigger: abort.future);
      await eventually(() => fake.attemptPid(1));
      abort.complete();

      await expectLater(opening, throwsA(isA<SshTunnelAbortedException>()));
      expect(await stops(fake.attemptPid(1)!), isTrue);
    });

    test('one of two tunnels waiting keeps the login for the other', () async {
      fake.attemptModes([AttemptMode.held]);
      final abort = Completer<void>();

      final first = open(abortTrigger: abort.future);
      final second = open();
      await eventually(() => fake.attemptPid(1));
      abort.complete();
      await expectLater(first, throwsA(isA<SshTunnelAbortedException>()));

      logIn();
      final tunnel = await second;

      expect(fake.attempts, hasLength(1));
      expect(operations(), [forwardOf(tunnel)]);
    });

    test('while -O forward runs stops it and cancels the forward', () async {
      fake
        ..attemptModes([AttemptMode.ready])
        ..muxModes(['hang', 'ok']);
      final abort = Completer<void>();

      final opening = openRemote(remotePort: 8080, abortTrigger: abort.future);
      await eventually(() => fake.muxCommands.isEmpty ? null : true);
      abort.complete();

      await expectLater(opening, throwsA(isA<SshTunnelAbortedException>()));
      await eventually(() => operations().length == 2 ? true : null);
      expect(operations(), [
        'forward 127.0.0.1:8080:localhost:3000',
        'cancel 127.0.0.1:8080:localhost:3000',
      ]);
    });
  });

  test('an address this computer lacks fails before the shared login',
      () async {
    final shared =
        SystemSshClient(executable: fake.path, shareConnections: true);

    await expectLater(
      shared.openSocksProxy(server, bindAddress: '192.0.2.1'),
      throwsA(isA<SshException>()),
    );
    expect(fake.attempts, isEmpty);
  });

  test('SystemSshClient shares only when asked', () async {
    fake.attemptModes([AttemptMode.ready]);

    final shared =
        SystemSshClient(executable: fake.path, shareConnections: true);
    final proxy = await shared.openSocksProxy(server);
    addTearDown(proxy.close);
    final tunnel = await shared.openTunnel(
      server,
      remoteHost: 'db.example.com',
      remotePort: 3306,
    );
    addTearDown(tunnel.close);
    expect(fake.attempts, hasLength(1));
    expect(operations(), [
      'forward 127.0.0.1:${proxy.localPort}',
      forwardOf(tunnel),
    ]);

    final elsewhere =
        await shared.openSocksProxy(server, bindAddress: '0.0.0.0');
    addTearDown(elsewhere.close);
    expect(operations().last, 'forward 0.0.0.0:${elsewhere.localPort}');

    final own =
        await SystemSshClient(executable: fake.path).openSocksProxy(server);
    addTearDown(own.close);
    expect(fake.attempts, hasLength(2));
    expect(fake.attempts.last, contains('ControlPath=none'));
  });
}
