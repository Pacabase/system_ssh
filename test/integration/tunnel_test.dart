@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:system_ssh/src/forwards.dart';
import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import '../fakes/fakes.dart';
import 'ssh_fixture.dart';

void main() {
  final fixture = SshFixture();

  group('SystemSshClient', skip: fixture.skip, () {
    setUpAll(() async {
      await fixture.setUpAll();
      await fixture.rememberHostKeyForBareTarget();
    });
    tearDownAll(fixture.tearDownAll);
    setUp(fixture.setUp);
    tearDown(fixture.tearDown);

    final logged = fixture.logged;

    Future<SshTunnel> open({
      SshTarget? via,
      int? remotePort,
      int? localPort,
      CountingPorts? ports,
      void Function(SshLog log)? onLog,
      Future<void>? abortTrigger,
    }) async {
      final tunnel = await openSystemForward(
        via ?? fixture.target,
        forward:
            localForwardTo(fixture.echoHost, remotePort ?? fixture.echoPort),
        localPort: localPort,
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

    group('on a bind address', () {
      InternetAddress? lan;

      setUpAll(() async {
        final addresses = [
          for (final interface
              in await NetworkInterface.list(type: InternetAddressType.IPv4))
            ...interface.addresses.where((address) => !address.isLoopback),
        ];
        lan = addresses.firstOrNull;
      });

      Future<String> echoAt(InternetAddress address, int port) async {
        final socket = await Socket.connect(address, port);
        addTearDown(socket.destroy);
        socket.done.ignore();
        socket.add(utf8.encode('ping'));
        return utf8.decode(
          await socket
              .expand((chunk) => chunk)
              .take(4)
              .toList()
              .timeout(const Duration(seconds: 5)),
        );
      }

      Future<SshTunnel> openOn(String address) async {
        final tunnel =
            await SystemSshClient(executable: fixture.ssh).openTunnel(
          fixture.target,
          remoteHost: fixture.echoHost,
          remotePort: fixture.echoPort,
          bindAddress: address,
          onLog: logged(),
        );
        addTearDown(tunnel.close);
        return tunnel;
      }

      test('0.0.0.0 forwards from every IPv4 address', () async {
        final here = lan;
        if (here == null) {
          return markTestSkipped('no IPv4 address but loopback');
        }
        final tunnel = await openOn('0.0.0.0');

        expect(await echoAt(here, tunnel.localPort), 'ping');
        expect(
          await echoAt(InternetAddress.loopbackIPv4, tunnel.localPort),
          'ping',
        );
      });

      test('another address forwards from it alone', () async {
        final here = lan;
        if (here == null) {
          return markTestSkipped('no IPv4 address but loopback');
        }
        final tunnel = await openOn(here.address);

        expect(await echoAt(here, tunnel.localPort), 'ping');
        await expectLater(
          Socket.connect(InternetAddress.loopbackIPv4, tunnel.localPort),
          throwsA(isA<SocketException>()),
        );
      });
    });

    test('forwards the local port to host and port once ssh says so', () async {
      final logs = <SshLog>[];
      final tunnel = await open(onLog: logs.add);

      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');
      expect(
        logs,
        contains(
          isA<SshProgress>().having(
            (log) => log.line,
            'line',
            contains('Local forwarding listening'),
          ),
        ),
      );
      expect(logs.last.line, contains('Entering interactive session'));
    });

    test('asks about a new host key when the config does, then trusts it',
        () async {
      fixture.forgetHostKey();
      final client = SystemSshClient(executable: fixture.ssh);

      final unknown = await open().then<Object?>(
        (_) => null,
        onError: (Object exception) => exception,
      );
      expect(
        unknown,
        isA<SshUnknownHostKeyException>()
            .having((exception) => exception.hostKey.host, 'host',
                fixture.hostKeyName)
            .having((exception) => exception.hostKey.fingerprint, 'fingerprint',
                startsWith('SHA256:')),
      );
      expect(await fixture.isKnownHost(), isFalse);

      await client.trustHostKey(
        fixture.target,
        (unknown! as SshUnknownHostKeyException).hostKey,
      );

      expect(await fixture.isKnownHost(), isTrue);
      final tunnel = await open();
      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');
    });

    test("doesn't trust a key other than the one the server offers", () async {
      fixture.forgetHostKey();

      await expectLater(
        SystemSshClient(executable: fixture.ssh).trustHostKey(
          fixture.target,
          SshHostKey(
            host: fixture.hostKeyName,
            type: 'ED25519',
            fingerprint: 'SHA256:fakeHostKeyFingerprintFakeHostKeyFingerpri',
          ),
        ),
        throwsA(
          isA<SshUnknownHostKeyException>().having(
            (exception) => exception.hostKey.fingerprint,
            'fingerprint',
            allOf(startsWith('SHA256:'), isNot(contains('fakeHostKey'))),
          ),
        ),
      );
      expect(await fixture.isKnownHost(), isFalse);
    });

    test("trusts a new key into the runner's own ~/.ssh/known_hosts", () async {
      await fixture.forgetHostKeyForBareTarget();
      addTearDown(fixture.rememberHostKeyForBareTarget);
      const client = SystemSshClient();
      Future<SshTunnel> openBare() => client.openTunnel(
            fixture.bareTarget,
            remoteHost: fixture.echoHost,
            remotePort: fixture.echoPort,
            onLog: logged(),
          );

      final unknown = await openBare().then<Object?>(
        (tunnel) => tunnel.close(),
        onError: (Object exception) => exception,
      );
      expect(unknown, isA<SshUnknownHostKeyException>());

      await client.trustHostKey(
        fixture.bareTarget,
        (unknown! as SshUnknownHostKeyException).hostKey,
      );

      final tunnel = await openBare();
      addTearDown(tunnel.close);
      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');
    });

    test('refuses a new host key under StrictHostKeyChecking yes', () async {
      fixture.forgetHostKey();

      await expectLater(
        open(via: fixture.strictTarget),
        throwsA(
          isA<SshHostKeyRefusedException>().having(
              (exception) => exception.message,
              'message',
              contains('Host key verification failed')),
        ),
      );
      expect(await fixture.isKnownHost(), isFalse);
    });

    test('refuses a changed host key, and trusting another over it', () async {
      await fixture.rememberWrongHostKey();
      final wrong = await fixture.knownHostsText();

      final changed = await open().then<Object?>(
        (_) => null,
        onError: (Object exception) => exception,
      );
      expect(
        changed,
        isA<SshHostKeyChangedException>().having(
            (exception) => exception.hostKey.host, 'host', fixture.hostKeyName),
      );
      await expectLater(
        SystemSshClient(executable: fixture.ssh).trustHostKey(
          fixture.target,
          (changed! as SshHostKeyChangedException).hostKey,
        ),
        throwsA(isA<SshHostKeyChangedException>()),
      );
      expect(await fixture.knownHostsText(), wrong);
    });

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
        throwsA(
          isA<SshFailedException>().having(
            (exception) => exception.message,
            'message',
            contains('cannot listen to port'),
          ),
        ),
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
      final logs = <SshLog>[];
      final tunnel = await open(remotePort: port, onLog: logs.add);
      logs.clear();

      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), isEmpty);
      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), isEmpty);
      // Windows' sshd opens the channel and closes it, so ssh has nothing to
      // warn about; other servers say the destination refused.
      if (!Platform.isWindows) {
        for (var waited = 0; waited < 50; waited++) {
          if (logs.any((log) => log is SshForwardFailed)) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          logs,
          contains(
            isA<SshForwardUnreachable>()
                .having((log) => log.reason, 'reason', 'Connection refused'),
          ),
        );
      }
    });

    group('says why it failed', () {
      Future<void> expectFailure(
        Future<SshTunnel> Function(void Function(SshLog log) onLog) open,
        Matcher failure,
      ) async {
        await expectLater(
          open(logged()).then((tunnel) => tunnel.close()),
          throwsA(failure),
        );
      }

      test('with SshNotFoundException for an ssh that is not there', () {
        final missing = '${Directory.systemTemp.path}'
            '${Platform.pathSeparator}no_such_ssh_$pid';

        return expectFailure(
          (onLog) => SystemSshClient(executable: missing).openTunnel(
            fixture.target,
            remoteHost: fixture.echoHost,
            remotePort: fixture.echoPort,
            onLog: onLog,
          ),
          isA<SshNotFoundException>(),
        );
      });

      test('with SshHostNotFoundException for a name that does not resolve',
          () {
        return expectFailure(
          (onLog) => SystemSshClient(executable: fixture.ssh).openTunnel(
            const SshTarget('no-such-host.invalid'),
            remoteHost: fixture.echoHost,
            remotePort: fixture.echoPort,
            onLog: onLog,
          ),
          isA<SshHostNotFoundException>(),
        );
      });

      test('with SshUnreachableException for a port nothing listens on',
          () async {
        final closed = await pickFreePort();

        await expectFailure(
          (onLog) => SystemSshClient(executable: fixture.ssh).openTunnel(
            SshTarget('127.0.0.1', port: closed),
            remoteHost: fixture.echoHost,
            remotePort: fixture.echoPort,
            onLog: onLog,
          ),
          isA<SshUnreachableException>(),
        );
      });

      test('with SshConfigException for a config that clears every forward',
          () {
        return expectFailure(
          (onLog) => SystemSshClient(executable: fixture.ssh).openTunnel(
            fixture.clearForwardingsTarget,
            remoteHost: fixture.echoHost,
            remotePort: fixture.echoPort,
            onLog: onLog,
          ),
          isA<SshConfigException>(),
        );
      });

      test('with SshAddressUnavailableException for an address not here', () {
        // TEST-NET-1, which no computer has.
        return expectFailure(
          (onLog) => SystemSshClient(executable: fixture.ssh).openTunnel(
            fixture.target,
            remoteHost: fixture.echoHost,
            remotePort: fixture.echoPort,
            bindAddress: '192.0.2.1',
            onLog: onLog,
          ),
          isA<SshAddressUnavailableException>().having(
            (exception) => exception.address,
            'address',
            '192.0.2.1',
          ),
        );
      });

      test('with SshForwardProhibited when the server forbids the forward',
          () async {
        final logs = <SshLog>[];
        final tunnel =
            await SystemSshClient(executable: fixture.ssh).openTunnel(
          fixture.noForwardingTarget,
          remoteHost: fixture.echoHost,
          remotePort: fixture.echoPort,
          onLog: logged(logs.add),
        );
        addTearDown(tunnel.close);

        expect(await fixture.echoThrough(tunnel.localPort, 'ping'), isEmpty);
        for (var waited = 0; waited < 50; waited++) {
          if (logs.any((log) => log is SshForwardFailed)) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(logs, contains(isA<SshForwardProhibited>()));
      });
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
          forward: DynamicForward.new,
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

    group('through a ProxyCommand', () {
      test('close stops the ProxyCommand too', () async {
        final tunnel = await open(via: fixture.proxyCommandTarget);
        expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');
        final proxy = await fixture.proxyPid;
        addTearDown(() => Process.killPid(proxy, ProcessSignal.sigkill));
        expect(isRunning(proxy), isTrue);

        await tunnel.close();

        expect(await stops(proxy), isTrue);
      });

      test('done says why when the ProxyCommand dies', () async {
        final tunnel = await open(via: fixture.proxyCommandTarget);
        expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');

        Process.killPid(await fixture.proxyPid, ProcessSignal.sigkill);

        await expectLater(
          tunnel.done.timeout(const Duration(seconds: 20)),
          throwsA(isA<SshDroppedException>()),
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
