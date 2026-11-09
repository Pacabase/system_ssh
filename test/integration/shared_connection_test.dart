// Windows' OpenSSH can't share a connection.
@TestOn('!windows')
@Tags(['integration'])
library;

import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/shared_connection.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import '../fakes/fakes.dart';
import 'ssh_fixture.dart';

void main() {
  final fixture = SshFixture();

  group('A shared connection', skip: fixture.skip, () {
    late ConnectionPool pool;

    setUpAll(fixture.setUpAll);
    tearDownAll(fixture.tearDownAll);
    setUp(() async {
      await fixture.setUp();
      pool = ConnectionPool();
    });
    tearDown(fixture.tearDown);

    void Function(SshLog log) logged(List<SshLog> logs) {
      addTearDown(
        () => printOnFailure(
          'ssh log:\n${logs.map((log) => log.line).join('\n')}',
        ),
      );
      return logs.add;
    }

    Future<SshTunnel> open({SshTarget? via, List<SshLog>? logs}) async {
      final tunnel = await openSystemForward(
        via ?? fixture.target,
        forward: localForwardTo(fixture.echoHost, fixture.echoPort),
        onLog: logged(logs ?? []),
        executable: fixture.ssh,
        pool: pool,
      );
      addTearDown(tunnel.close);
      return tunnel;
    }

    bool loggedIn(List<SshLog> logs) =>
        logs.any((log) => log.line.startsWith('Authenticated to '));

    test('logs in once for two tunnels, and both forward', () async {
      final firstLogs = <SshLog>[];
      final secondLogs = <SshLog>[];

      final first = await open(logs: firstLogs);
      final second = await open(logs: secondLogs);

      expect(loggedIn(firstLogs), isTrue);
      expect(loggedIn(secondLogs), isFalse);
      expect(await fixture.echoThrough(first.localPort, 'one'), 'one');
      expect(await fixture.echoThrough(second.localPort, 'two'), 'two');
    });

    test('closing one tunnel frees its port and keeps the other', () async {
      final first = await open();
      final second = await open();

      await first.close();

      expect(await isPortFree(first.localPort), isTrue);
      expect(await fixture.echoThrough(second.localPort, 'ping'), 'ping');
    });

    test('logs in again once the last tunnel has closed', () async {
      final first = await open();
      await first.close();
      final logs = <SshLog>[];

      final second = await open(logs: logs);

      expect(loggedIn(logs), isTrue);
      expect(await fixture.echoThrough(second.localPort, 'ping'), 'ping');
    });

    test('forwards a remote port the server picks, and cancels it', () async {
      await open();
      final remote = await openSystemRemoteForward(
        fixture.target,
        localHost: fixture.echoHost,
        localPort: fixture.echoPort,
        onLog: logged([]),
        executable: fixture.ssh,
        pool: pool,
      );
      addTearDown(remote.close);

      expect(remote.remotePort, isNot(0));
      expect(await fixture.echoThrough(remote.remotePort, 'ping'), 'ping');

      await remote.close();
      // sshd lets go of the port once it handles the cancel.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await isPortFree(remote.remotePort)) {
        if (DateTime.now().isAfter(deadline)) fail('the port stayed bound');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });

    test('tells only the tunnel used that its destination refused', () async {
      final closed = await pickFreePort();
      final refusedLogs = <SshLog>[];
      final otherLogs = <SshLog>[];
      final refusing = await openSystemForward(
        fixture.target,
        forward: localForwardTo(fixture.echoHost, closed),
        onLog: logged(refusedLogs),
        executable: fixture.ssh,
        pool: pool,
      );
      addTearDown(refusing.close);
      await open(logs: otherLogs);
      refusedLogs.clear();
      otherLogs.clear();

      expect(await fixture.echoThrough(refusing.localPort, 'ping'), isEmpty);
      for (var waited = 0; waited < 50; waited++) {
        if (refusedLogs.any((log) => log is SshForwardFailed)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(
        refusedLogs,
        contains(
          isA<SshForwardFailed>()
              .having((log) => log.reason, 'reason', 'Connection refused'),
        ),
      );
      expect(otherLogs, isNot(contains(isA<SshForwardFailed>())));
    });

    test('stops a ProxyCommand once the last tunnel closes', () async {
      final first = await open(via: fixture.proxyCommandTarget);
      final second = await open(via: fixture.proxyCommandTarget);
      final proxy = await fixture.proxyPid;

      await first.close();
      expect(isRunning(proxy), isTrue);

      await second.close();
      expect(await stops(proxy), isTrue);
    });
  });
}
