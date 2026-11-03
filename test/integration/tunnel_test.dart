@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import '../fakes/fakes.dart';
import 'ssh_fixture.dart';

void main() {
  final fixture = SshFixture();

  group('SystemSshClient', skip: fixture.skip, () {
    setUpAll(fixture.setUpAll);
    tearDownAll(fixture.tearDownAll);
    setUp(fixture.setUp);
    tearDown(fixture.tearDown);

    Matcher sshFailure(String reason) => throwsA(
          isA<SshTunnelException>().having(
            (exception) => exception.message,
            'message',
            contains(reason),
          ),
        );

    void Function(String line) logged([void Function(String line)? onLog]) {
      final log = <String>[];
      addTearDown(() => printOnFailure('ssh log:\n${log.join('\n')}'));
      return (line) {
        log.add(line);
        onLog?.call(line);
      };
    }

    Future<SshTunnel> open({
      SshTarget? via,
      int? remotePort,
      CountingPorts? ports,
      void Function(String line)? onLog,
      Future<void>? abortTrigger,
    }) async {
      final tunnel = await openSystemTunnel(
        via ?? fixture.target,
        remoteHost: fixture.echoHost,
        remotePort: remotePort ?? fixture.echoPort,
        onLog: logged(onLog),
        abortTrigger: abortTrigger,
        executable: fixture.ssh,
        freePort: (ports ?? CountingPorts()).next,
      );
      addTearDown(tunnel.close);
      return tunnel;
    }

    test('forwards through the system ssh with no config', () async {
      final tunnel = await const SystemSshClient().openTunnel(
        fixture.bareTarget,
        remoteHost: fixture.echoHost,
        remotePort: fixture.echoPort,
        onLog: logged(),
      );
      addTearDown(tunnel.close);

      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');
    });

    test('forwards the local port to host and port once ssh says so', () async {
      final lines = <String>[];
      final tunnel = await open(onLog: lines.add);

      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');
      expect(lines, contains(contains('Local forwarding listening')));
      expect(lines.last, contains('Entering interactive session'));
    });

    test('accepts and remembers a new host key when the config asks', () async {
      expect(await fixture.isKnownHost(), isFalse);

      await open();

      expect(await fixture.isKnownHost(), isTrue);
    });

    test('refuses a new host key under StrictHostKeyChecking yes', () async {
      await expectLater(
        open(via: fixture.strictTarget),
        sshFailure('Host key verification failed'),
      );
      expect(await fixture.isKnownHost(), isFalse);
    });

    test(
      'refuses a changed host key even when new ones are accepted',
      () async {
        await fixture.rememberWrongHostKey();

        await expectLater(open(), sshFailure('Host key verification failed'));
      },
    );

    test('retries with a fresh port when the picked one is taken', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);
      final ports = CountingPorts(
        (pick) async => pick == 1 ? taken.port : pickFreePort(),
      );

      final tunnel = await open(ports: ports);

      expect(ports.picks, 2);
      expect(tunnel.localPort, isNot(taken.port));
      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');
    });

    test('gives up after three taken ports', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);
      final ports = CountingPorts((_) async => taken.port);

      await expectLater(
        open(ports: ports),
        sshFailure('cannot listen to port'),
      );
      expect(ports.picks, 3);
    });

    test('opens to a port that refuses, and each connection ends', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();

      final tunnel = await open(remotePort: port);

      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), isEmpty);
      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), isEmpty);
    });

    test('aborts through abortTrigger while ssh connects', () async {
      final abort = Completer<void>();

      await expectLater(
        open(
          abortTrigger: abort.future,
          onLog: (_) {
            if (!abort.isCompleted) abort.complete();
          },
        ),
        throwsA(isA<SshTunnelAbortedException>()),
      );
    });

    test('close stops a working tunnel forwarding', () async {
      final tunnel = await open();
      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');

      await tunnel.close();

      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, tunnel.localPort),
        throwsA(isA<SocketException>()),
      );
    });

    test('done completes after close', () async {
      final tunnel = await open();

      await tunnel.close();

      await expectLater(
        tunnel.done.timeout(const Duration(seconds: 5)),
        completes,
      );
    });
  });
}
