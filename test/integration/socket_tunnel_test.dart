// The test serves a Unix socket, which dart:io can't on Windows.
@TestOn('!windows')
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import '../fakes/fakes.dart';
import 'ssh_fixture.dart';

// The sshd runs on this machine, so a socket here is on the server too.
void main() {
  final fixture = SshFixture();

  group('A socket tunnel', skip: fixture.skip, () {
    late String socketPath;

    setUpAll(fixture.setUpAll);
    tearDownAll(fixture.tearDownAll);
    setUp(() async {
      await fixture.setUp();
      final directory = Directory.systemTemp.createTempSync('sock');
      addTearDown(() => deleteSoon(directory));
      socketPath = '${directory.path}/echo.sock';
    });
    tearDown(fixture.tearDown);

    Future<SshTunnel> open({void Function(SshLog log)? onLog}) async {
      final lines = <String>[];
      addTearDown(() => printOnFailure('ssh log:\n${lines.join('\n')}'));
      final tunnel =
          await SystemSshClient(executable: fixture.ssh).openSocketTunnel(
        fixture.target,
        remoteSocket: socketPath,
        onLog: (log) {
          lines.add(log.line);
          onLog?.call(log);
        },
      );
      addTearDown(tunnel.close);
      return tunnel;
    }

    test('forwards the local port to the Unix socket', () async {
      final echo = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(echo.close);
      echo.listen((socket) => socket.listen(socket.add, onDone: socket.close));

      final tunnel = await open();

      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), 'ping');
    });

    test('stays open and logs a connection to a missing socket', () async {
      final logs = <SshLog>[];
      final tunnel = await open(onLog: logs.add);
      var isDone = false;
      unawaited(tunnel.done.whenComplete(() => isDone = true));

      expect(await fixture.echoThrough(tunnel.localPort, 'ping'), isEmpty);
      for (var waited = 0; waited < 50; waited++) {
        if (logs.any((log) => log is SshForwardFailed)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(logs, contains(isA<SshForwardFailed>()));
      expect(isDone, isFalse);
    });
  });
}
