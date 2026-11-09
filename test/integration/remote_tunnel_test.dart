@Tags(['integration'])
library;

import 'dart:io';

import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'ssh_fixture.dart';

// The sshd runs on this machine, so its 127.0.0.1 is ours: a connection to the
// server's port comes back through ssh to the echo server.
void main() {
  final fixture = SshFixture();

  group('A remote tunnel', skip: fixture.skip, () {
    setUpAll(fixture.setUpAll);
    tearDownAll(fixture.tearDownAll);
    setUp(fixture.setUp);
    tearDown(fixture.tearDown);

    Future<SshRemoteTunnel> open({
      int? remotePort,
      void Function(SshLog log)? onLog,
    }) async {
      final lines = <String>[];
      addTearDown(() => printOnFailure('ssh log:\n${lines.join('\n')}'));
      final tunnel = await openSystemRemoteForward(
        fixture.target,
        localHost: fixture.echoHost,
        localPort: fixture.echoPort,
        remotePort: remotePort,
        onLog: (log) {
          lines.add(log.line);
          onLog?.call(log);
        },
        executable: fixture.ssh,
      );
      addTearDown(tunnel.close);
      return tunnel;
    }

    test('forwards a fixed server port back to the local one', () async {
      final port = await pickFreePort();

      final tunnel = await open(remotePort: port);

      expect(tunnel.remotePort, port);
      expect(await fixture.echoThrough(port, 'ping'), 'ping');
    });

    test('forwards a port the server picks', () async {
      final logs = <SshLog>[];

      final tunnel = await open(onLog: logs.add);

      expect(tunnel.remotePort, isNot(0));
      expect(await fixture.echoThrough(tunnel.remotePort, 'ping'), 'ping');
      expect(
        logs,
        contains(
          isA<SshProgress>().having(
            (log) => log.line,
            'line',
            startsWith('Allocated port ${tunnel.remotePort} '),
          ),
        ),
      );
    });

    test('says why when the server port is taken', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);

      await expectLater(
        open(remotePort: taken.port),
        throwsA(
          isA<SshTunnelException>().having(
            (exception) => exception.message,
            'message',
            contains('remote port forwarding failed'),
          ),
        ),
      );
    });

    test('close frees the server port', () async {
      final tunnel = await open(remotePort: await pickFreePort());

      await tunnel.close();
      await tunnel.done;

      // sshd lets go of the port once it sees the session end.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await isPortFree(tunnel.remotePort)) {
        if (DateTime.now().isAfter(deadline)) fail('the port stayed bound');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
  });
}
