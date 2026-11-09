import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/ssh_command.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';

void main() {
  const server = SshTarget('ssh.example.com');
  const socket = '/var/run/docker.sock';

  group('checkSocketPath', () {
    test('takes an absolute path', () {
      checkSocketPath('/var/run/postgresql/.s.PGSQL.5432', 'remoteSocket');
      checkSocketPath('/tmp/with space.sock', 'remoteSocket');
    });

    for (final path in [
      'docker.sock',
      'run/docker.sock',
      '~/docker.sock',
      '',
      '/run/a:b.sock',
      '/run/%h.sock',
      r'/run/${HOME}.sock',
      '/run/a\nb.sock',
    ]) {
      test('rejects ${path.replaceAll('\n', r'\n')}', () {
        expect(
          () => checkSocketPath(path, 'remoteSocket'),
          throwsA(
            isA<ArgumentError>()
                .having((error) => error.name, 'name', 'remoteSocket'),
          ),
        );
      });
    }
  });

  test('forwards the local port to the socket path', () {
    expect(
      localForwardToSocket(50000, remoteSocket: socket),
      ['-L', '127.0.0.1:50000:/var/run/docker.sock'],
    );
  });

  group('openSocketTunnel', () {
    late FakeSsh fake;

    setUp(() async => fake = await FakeSsh.create());

    test('opens on a free port with the -L command for the socket', () async {
      fake.attemptModes([AttemptMode.ready]);

      final tunnel = await SystemSshClient(executable: fake.path)
          .openSocketTunnel(server, remoteSocket: socket);
      addTearDown(tunnel.close);

      expect(fake.attempts, [
        sshCommand(
          server,
          forward: localForwardToSocket(
            tunnel.localPort,
            remoteSocket: socket,
          ),
        ).sublist(1),
      ]);
    });

    test('opens on a fixed local port', () async {
      fake.attemptModes([AttemptMode.ready]);
      final port = await pickFreePort();

      final tunnel = await SystemSshClient(executable: fake.path)
          .openSocketTunnel(server, remoteSocket: socket, localPort: port);
      addTearDown(tunnel.close);

      expect(tunnel.localPort, port);
      expect(fake.attempts.single, contains('127.0.0.1:$port:$socket'));
    });

    test('rejects a relative socket path before running ssh', () async {
      await expectLater(
        SystemSshClient(executable: fake.path)
            .openSocketTunnel(server, remoteSocket: 'docker.sock'),
        throwsArgumentError,
      );
      expect(fake.configArguments, isNull);
    });

    test('says why when ssh fails', () async {
      fake.attemptModes([AttemptMode.fail]);

      await expectLater(
        SystemSshClient(executable: fake.path)
            .openSocketTunnel(server, remoteSocket: socket),
        throwsA(
          isA<SshTunnelException>().having(
            (exception) => exception.message,
            'message',
            contains('Connection refused'),
          ),
        ),
      );
    });
  });
}
