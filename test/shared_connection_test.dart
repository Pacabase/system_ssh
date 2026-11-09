// Windows' OpenSSH can't share a connection, so the pool never runs there.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/shared_connection.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';
import 'fakes/fakes.dart';

void main() {
  const server = SshTarget('ssh.example.com');
  late FakeSsh fake;
  late ConnectionPool pool;

  setUp(() async {
    fake = await FakeSsh.create();
    pool = ConnectionPool();
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

  Future<SshRemoteTunnel> openRemote({int? remotePort}) async {
    final tunnel = await openSystemRemoteForward(
      server,
      localHost: 'localhost',
      localPort: 3000,
      remotePort: remotePort,
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
    expect(operations(), [
      'forward 127.0.0.1:${first.localPort}:db.example.com:3306',
      'forward 127.0.0.1:${second.localPort}:db.example.com:3306',
    ]);
    expect(
      fake.muxCommands.first,
      contains(
        fake.attempts.single.firstWhere(
          (argument) => argument.startsWith('ControlPath='),
        ),
      ),
    );
  });

  test('closing one tunnel cancels its forward and keeps the master', () async {
    fake.attemptModes([AttemptMode.ready]);
    final first = await open();
    await open();

    await first.close();

    expect(
        operations().last, startsWith('cancel 127.0.0.1:${first.localPort}'));
    expect(isRunning(fake.attemptPid(1)!), isTrue);
  });

  test('the last close stops the master, and the next tunnel starts one',
      () async {
    fake.attemptModes([AttemptMode.ready]);
    final first = await open();
    final second = await open();

    await first.close();
    await second.close();

    expect(await stops(fake.attemptPid(1)!), isTrue);
    await expectLater(first.done, completes);

    await open();
    expect(fake.attempts, hasLength(2));
  });

  test('tunnels opened together wait on one login', () async {
    fake.attemptModes([AttemptMode.ready]);

    final tunnels = await Future.wait([open(), open(), open()]);

    expect(fake.attempts, hasLength(1));
    expect(tunnels.map((tunnel) => tunnel.localPort).toSet(), hasLength(3));
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
    expect(operations().last, contains('127.0.0.1:${tunnel.localPort}:'));
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

  test('a dropped master fails every tunnel on it', () async {
    fake.attemptModes([AttemptMode.ready]);
    final first = await open();
    final second = await open();

    Process.killPid(fake.attemptPid(1)!, ProcessSignal.sigkill);

    await expectLater(first.done, throwsA(isA<SshTunnelException>()));
    await expectLater(second.done, throwsA(isA<SshTunnelException>()));

    await open();
    expect(fake.attempts, hasLength(2));
  });

  test("routes a failed connection to its own tunnel's onLog", () async {
    fake.attemptModes([AttemptMode.ready]);
    final firstLogs = <SshLog>[];
    final secondLogs = <SshLog>[];
    final first = await open(onLog: firstLogs.add);
    await open(onLog: secondLogs.add);
    firstLogs.clear();
    secondLogs.clear();

    fake
      ..masterSays('mux_master_process_open_fwd: requested local forward '
          '127.0.0.1:1 -> db.example.com:3306 failed')
      ..masterSays('channel 3: open failed: connect failed: Connection refused')
      ..masterSays('debug1: channel 3: free: direct-tcpip: listening port '
          '${first.localPort} for db.example.com port 3306, connect from '
          '127.0.0.1 port 50123 to 127.0.0.1 port ${first.localPort}, '
          'nchannels 4')
      ..masterSays('Warning: the server says hello');

    await eventually(() => secondLogs.isEmpty ? null : true);

    expect(firstLogs, [
      const SshForwardFailed(
        'channel 3: open failed: connect failed: Connection refused',
        reason: 'Connection refused',
      ),
      const SshMessage('Warning: the server says hello'),
    ]);
    expect(secondLogs, [const SshMessage('Warning: the server says hello')]);
  });

  test('passes the login to the onLog of each tunnel waiting on it', () async {
    fake.attemptModes([AttemptMode.ready]);
    final logs = <SshLog>[];

    await open(onLog: logs.add);

    expect(
      logs,
      contains(const SshProgress('debug1: Entering interactive session.')),
    );
  });

  test('a cancel that fails stops new tunnels joining the master', () async {
    fake
      ..attemptModes([AttemptMode.ready])
      ..muxModes(['ok', 'ok', 'silent-fail', 'ok']);
    final first = await open();
    await open();

    await first.close();
    await open();

    expect(fake.attempts, hasLength(2));
  });

  group('aborting while it logs in', () {
    test('stops the master when no other tunnel waits', () async {
      fake.attemptModes([AttemptMode.hang]);
      final abort = Completer<void>();

      final opening = open(abortTrigger: abort.future);
      await eventually(() => fake.attemptPid(1));
      abort.complete();

      await expectLater(opening, throwsA(isA<SshTunnelAbortedException>()));
      expect(await stops(fake.attemptPid(1)!), isTrue);
    });

    test('keeps logging in for another tunnel', () async {
      fake.attemptModes([AttemptMode.hang]);
      final abortFirst = Completer<void>();
      final abortSecond = Completer<void>();

      final first = open(abortTrigger: abortFirst.future);
      final second = open(abortTrigger: abortSecond.future);
      await eventually(() => fake.attemptPid(1));

      abortFirst.complete();
      await expectLater(first, throwsA(isA<SshTunnelAbortedException>()));
      expect(isRunning(fake.attemptPid(1)!), isTrue);

      abortSecond.complete();
      await expectLater(second, throwsA(isA<SshTunnelAbortedException>()));
      expect(await stops(fake.attemptPid(1)!), isTrue);
    });
  });

  test('SystemSshClient shares only when asked', () async {
    fake.attemptModes([AttemptMode.ready]);

    final shared =
        SystemSshClient(executable: fake.path, shareConnections: true);
    final first = await shared.openSocksProxy(server);
    addTearDown(first.close);
    final second = await shared.openTunnel(
      server,
      remoteHost: 'db.example.com',
      remotePort: 3306,
    );
    addTearDown(second.close);
    expect(fake.attempts, hasLength(1));

    final own =
        await SystemSshClient(executable: fake.path).openSocksProxy(server);
    addTearDown(own.close);
    expect(fake.attempts, hasLength(2));
    expect(fake.attempts.last, contains('ControlPath=none'));
  });
}
