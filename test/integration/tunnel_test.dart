@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/ssh_command.dart';
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

    Matcher sshFailure(String reason, {bool isPermanent = true}) => throwsA(
          isA<SshTunnelException>()
              .having(
                (exception) => exception.message,
                'message',
                contains(reason),
              )
              .having(
                (exception) => exception.isPermanent,
                'isPermanent',
                isPermanent,
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
      int? localPort,
      CountingPorts? ports,
      void Function(String line)? onLog,
      void Function(String reason)? onRefused,
      Future<void>? abortTrigger,
    }) async {
      final tunnel = await openSystemForward(
        via ?? fixture.target,
        forward:
            localForwardTo(fixture.echoHost, remotePort ?? fixture.echoPort),
        localPort: localPort,
        onLog: logged(onLog),
        onRefused: onRefused,
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
        sshFailure('cannot listen to port', isPermanent: false),
      );
      expect(ports.picks, 3);
    });

    test('forwards a fixed local port', () async {
      final port = await pickFreePort();

      final tunnel = await open(localPort: port);

      expect(tunnel.localPort, port);
      expect(await fixture.echoThrough(port, 'ping'), 'ping');
    });

    test('fails on a fixed local port that is taken', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);

      await expectLater(
        open(localPort: taken.port),
        throwsA(
          isA<SshPortInUseException>()
              .having((exception) => exception.port, 'port', taken.port),
        ),
      );
    });

    test('opens to a port that refuses, and each connection ends', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();

      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = level);
      final everything = <String>[];
      final listening = Logger('system_ssh').onRecord.listen(
            (record) => everything.add(record.message),
          );
      addTearDown(listening.cancel);
      addTearDown(
        () => printOnFailure('all of ssh:\n${everything.join('\n')}'),
      );
      final warnings = <String>[];
      final reasons = <String>[];
      final tunnel = await open(
        remotePort: port,
        onLog: warnings.add,
        onRefused: reasons.add,
      );
      warnings.clear();

      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), isEmpty);
      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), isEmpty);
      // Windows' sshd opens the channel and closes it, so ssh has nothing to
      // warn about; other servers say the destination refused.
      if (!Platform.isWindows) {
        for (var waited = 0; waited < 50; waited++) {
          if (warnings.any((line) => line.contains('open failed'))) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(warnings, contains(contains('open failed')));
        expect(reasons, contains('Connection refused'));
      }
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

    group('SOCKS proxy', () {
      Future<SshTunnel> openProxy({int? localPort}) async {
        final proxy = await openSystemForward(
          fixture.target,
          forward: dynamicForward,
          localPort: localPort,
          onLog: logged(),
          executable: fixture.ssh,
        );
        addTearDown(proxy.close);
        return proxy;
      }

      Future<String> echoThroughProxy(int proxyPort, String message) async {
        final socket =
            await Socket.connect(InternetAddress.loopbackIPv4, proxyPort);
        addTearDown(socket.destroy);
        socket.done.ignore();
        final bytes = StreamIterator(socket.expand((chunk) => chunk));

        Future<List<int>> read(int count) async {
          final received = <int>[];
          while (received.length < count && await bytes.moveNext()) {
            received.add(bytes.current);
          }
          return received;
        }

        Future<String> talk() async {
          socket.add([5, 1, 0]);
          expect(await read(2), [5, 0]);

          final port = fixture.echoPort;
          socket.add([5, 1, 0, 1, 127, 0, 0, 1, port >> 8, port & 0xff]);
          expect((await read(10)).take(2), [5, 0]);

          socket.add(utf8.encode(message));
          return utf8.decode(await read(message.length));
        }

        return talk().timeout(const Duration(seconds: 5));
      }

      test('connects through the server to what the client asks for', () async {
        final proxy = await openProxy();

        expect(await echoThroughProxy(proxy.localPort, 'ping'), 'ping');
      });

      test('SystemSshClient serves a fixed local port', () async {
        final port = await pickFreePort();

        final proxy = await const SystemSshClient().openSocksProxy(
          fixture.bareTarget,
          localPort: port,
          onLog: logged(),
        );
        addTearDown(proxy.close);

        expect(proxy.localPort, port);
        expect(await echoThroughProxy(port, 'ping'), 'ping');
      });

      test('fails on a fixed local port that is taken', () async {
        final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(taken.close);

        await expectLater(
          openProxy(localPort: taken.port),
          throwsA(
            isA<SshPortInUseException>()
                .having((exception) => exception.port, 'port', taken.port),
          ),
        );
      });
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
