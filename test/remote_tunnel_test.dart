import 'dart:async';

import 'package:system_ssh/src/ssh_command.dart';
import 'package:system_ssh/src/ssh_output.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';
import 'fakes/fakes.dart';

void main() {
  const server = SshTarget('ssh.example.com');
  const session = 'debug1: Entering interactive session.';
  const forwarded = 'debug1: remote forward success for: '
      'listen 127.0.0.1:8080, connect localhost:3000';

  group('RemoteForwardReadiness', () {
    RemoteForwardReadiness readiness(int port) =>
        RemoteForwardReadiness(port, localHost: 'localhost', localPort: 3000);

    test('is ready once the server accepts and the session starts', () {
      final fixed = readiness(8080);

      expect(fixed.isReadyAfter(forwarded), isFalse);
      expect(fixed.isReadyAfter(session), isTrue);
      expect(fixed.port, 8080);
    });

    test('takes the session starting before the server answers', () {
      final fixed = readiness(8080);

      expect(fixed.isReadyAfter(session), isFalse);
      expect(fixed.isReadyAfter(forwarded), isTrue);
    });

    test('ignores a forward to another port', () {
      final fixed = readiness(8080)..isReadyAfter(session);

      expect(
        fixed.isReadyAfter(forwarded.replaceFirst('8080', '9090')),
        isFalse,
      );
      expect(fixed.isReadyAfter(forwarded.replaceFirst('8080', '80')), isFalse);
      expect(fixed.port, isNull);
    });

    test('is never ready after a refused forward', () {
      final fixed = readiness(8080)..isReadyAfter(session);

      expect(
        fixed.isReadyAfter(forwarded.replaceFirst('success', 'failure')),
        isFalse,
      );
    });

    test('takes the port the server picked for its own destination', () {
      final picked = readiness(0)
        ..isReadyAfter(session)
        ..isReadyAfter(forwarded.replaceFirst('8080', '0'))
        ..isReadyAfter(
          'Allocated port 50001 for remote forward to localhost:4000',
        );
      expect(picked.port, isNull);

      expect(
        picked.isReadyAfter(
          'Allocated port 41234 for remote forward to localhost:3000',
        ),
        isTrue,
      );
      expect(picked.port, 41234);
    });

    test("counts the server's picked port as progress, not a failure", () {
      const allocated =
          'Allocated port 41234 for remote forward to localhost:3000';

      expect(classify(allocated), const SshProgress(allocated));
    });
  });

  group('remoteForward', () {
    test('binds the server side to 127.0.0.1', () {
      expect(
        remoteForward(8080, localHost: 'localhost', localPort: 3000),
        ['-R', '127.0.0.1:8080:localhost:3000'],
      );
    });

    test('brackets an IPv6 local host', () {
      expect(
        remoteForward(0, localHost: '::1', localPort: 3000),
        ['-R', '127.0.0.1:0:[::1]:3000'],
      );
    });
  });

  group('validation', () {
    Future<SshRemoteTunnel> open({
      SshTarget target = server,
      String localHost = 'localhost',
      int localPort = 3000,
      int? remotePort,
    }) =>
        const SystemSshClient(executable: '/nonexistent/ssh').openRemoteTunnel(
          target,
          localHost: localHost,
          localPort: localPort,
          remotePort: remotePort,
        );

    test('rejects a server host ssh would read as an option', () {
      expect(
        open(target: const SshTarget('-oProxyCommand=evil')),
        throwsArgumentError,
      );
    });

    test('rejects a local host with shell characters', () {
      expect(open(localHost: 'localhost;rm'), throwsArgumentError);
      expect(open(localHost: 'local host'), throwsArgumentError);
    });

    test('rejects ports outside 1 to 65535', () {
      expect(
        open(localPort: 0),
        throwsA(isA<RangeError>()
            .having((exception) => exception.name, 'name', 'localPort')),
      );
      expect(
        open(remotePort: 65536),
        throwsA(isA<RangeError>()
            .having((exception) => exception.name, 'name', 'remotePort')),
      );
      expect(open(remotePort: 0), throwsRangeError);
    });
  });

  group('with a fake ssh', () {
    late FakeSsh fake;

    setUp(() async => fake = await FakeSsh.create());

    Future<SshRemoteTunnel> open({
      int? remotePort,
      Future<void>? abortTrigger,
      void Function(SshLog log)? onLog,
    }) async {
      final tunnel = await openSystemRemoteForward(
        server,
        localHost: 'localhost',
        localPort: 3000,
        remotePort: remotePort,
        executable: fake.path,
        abortTrigger: abortTrigger,
        onLog: onLog,
      );
      addTearDown(tunnel.close);
      return tunnel;
    }

    test('forwards the fixed remote port with the -R command', () async {
      fake.attemptModes([AttemptMode.ready]);

      final tunnel = await open(remotePort: 8080);

      expect(tunnel.remotePort, 8080);
      expect(fake.attempts, [
        sshCommand(
          server,
          forward: ['-R', '127.0.0.1:8080:localhost:3000'],
        ).sublist(1),
      ]);
    });

    test('returns the port the server picked', () async {
      fake.attemptModes([AttemptMode.ready]);
      final logs = <SshLog>[];

      final tunnel = await open(onLog: logs.add);

      expect(tunnel.remotePort, 41234);
      expect(fake.attempts.single, contains('127.0.0.1:0:localhost:3000'));
      expect(logs, everyElement(isA<SshProgress>()));
    });

    test('SystemSshClient runs its executable', () async {
      fake.attemptModes([AttemptMode.ready]);

      final tunnel = await SystemSshClient(executable: fake.path)
          .openRemoteTunnel(server, localPort: 3000, remotePort: 8080);
      addTearDown(tunnel.close);

      expect(tunnel.remotePort, 8080);
      expect(fake.attempts.single, contains('127.0.0.1:8080:localhost:3000'));
    });

    test('says why when the server refuses the port', () async {
      fake.attemptModes([AttemptMode.bindFailure]);

      await expectLater(
        open(remotePort: 8080),
        throwsA(
          isA<SshTunnelException>()
              .having(
                (exception) => exception.message,
                'message',
                'Error: remote port forwarding failed for listen port 8080',
              )
              .having(
                (exception) => exception.isPermanent,
                'isPermanent',
                isFalse,
              ),
        ),
      );
      expect(fake.attempts, hasLength(1));
    });

    test('throws SshNotFoundException when sh cannot find ssh', () async {
      fake.attemptModes([AttemptMode.notFound]);

      await expectLater(
        open(remotePort: 8080),
        throwsA(isA<SshNotFoundException>()),
      );
    });

    test('stops ssh when aborted while it connects', () async {
      fake.hangOnConfig();
      final abort = Completer<void>();

      final opening = open(remotePort: 8080, abortTrigger: abort.future);
      await fake.configPid;
      abort.complete();

      await expectLater(opening, throwsA(isA<SshTunnelAbortedException>()));
      expect(fake.attempts, isEmpty);
    });

    test('refuses a config that clears forwardings', () async {
      fake.answerConfig(['clearallforwardings yes']);

      await expectLater(
        open(remotePort: 8080),
        throwsA(isA<SshConfigException>()),
      );
      expect(fake.attempts, isEmpty);
    });

    test('close stops ssh, and done completes', () async {
      fake.attemptModes([AttemptMode.ready]);
      final tunnel = await open(remotePort: 8080);
      final pid = fake.attemptPid(1)!;

      await tunnel.close();
      await tunnel.close();

      expect(await stops(pid), isTrue);
      await expectLater(tunnel.done, completes);
    });
  });
}
