import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:system_ssh/src/ports.dart';
import 'package:system_ssh/src/ssh_command.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';
import 'fakes/fakes.dart';

void main() {
  const server = SshTarget('ssh.example.com');

  test('SystemSshClient runs ssh by default', () {
    expect(const SystemSshClient().executable, 'ssh');
  });

  test('throws SshNotFoundException when ssh is missing', () async {
    await expectLater(
      openSystemTunnel(
        server,
        remoteHost: 'db.example.com',
        remotePort: 3306,
        executable: '/nonexistent/ssh',
      ),
      throwsA(isA<SshNotFoundException>()),
    );
  });

  group('validation', () {
    Future<SshTunnel> open({
      SshTarget target = server,
      String remoteHost = 'db.example.com',
    }) async =>
        openSystemTunnel(
          target,
          remoteHost: remoteHost,
          remotePort: 3306,
          executable: '/nonexistent/ssh',
        );

    Matcher throwsInvalid(String name, String value) => throwsA(
          isArgumentError
              .having((error) => error.name, 'name', name)
              .having((error) => error.invalidValue, 'invalidValue', value),
        );

    const unsafe = [
      ' ',
      '\t',
      '\n',
      '\r',
      '\x00',
      '\x1b',
      "'",
      '"',
      '`',
      r'$',
      ';',
      '&',
      '|',
      '<',
      '>',
      '(',
      ')',
      '{',
      '}',
      '/',
    ];

    test('rejects a server host starting with -', () async {
      await expectLater(
        open(target: const SshTarget('-oProxyCommand=false')),
        throwsInvalid('server', '-oProxyCommand=false'),
      );
    });

    for (final character in [...unsafe, r'\']) {
      final host = 'ssh${character}example.com';

      test('rejects a server host holding ${_shown(character)}', () async {
        await expectLater(
          open(target: SshTarget(host)),
          throwsInvalid('server', host),
        );
      });

      test('rejects a remote host holding ${_shown(character)}', () async {
        await expectLater(
          open(remoteHost: host),
          throwsInvalid('remoteHost', host),
        );
      });
    }

    for (final character in unsafe) {
      final user = 'al${character}ice';

      test('rejects a user holding ${_shown(character)}', () async {
        await expectLater(
          open(target: SshTarget('ssh.example.com', user: user)),
          throwsInvalid('server', user),
        );
      });
    }

    for (final (name, target, remoteHost) in [
      (
        'a DOMAIN\\user',
        const SshTarget('ssh.example.com', user: r'CORP\alice'),
        'db.example.com'
      ),
      ('an IPv6 server', const SshTarget('fd00::5'), 'db.example.com'),
      ('an IPv6 remote host', server, '::1'),
      (
        'a user@ name',
        const SshTarget('ssh.example.com', user: 'alice@corp'),
        'db.example.com'
      ),
    ]) {
      test('accepts $name', () async {
        await expectLater(
          open(target: target, remoteHost: remoteHost),
          throwsA(isA<SshNotFoundException>()),
        );
      });
    }
  });

  group('with a fake ssh', () {
    late FakeSsh fake;
    late ServerSocket taken;

    setUp(() async {
      fake = await FakeSsh.create();
      taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);
    });

    Future<SshTunnel> open({
      SshTarget target = server,
      String remoteHost = 'db.example.com',
      CountingPorts? ports,
      Future<void>? abortTrigger,
      void Function(String line)? onLog,
      Duration configTimeout = const Duration(seconds: 5),
    }) async {
      final tunnel = await openSystemTunnel(
        target,
        remoteHost: remoteHost,
        remotePort: 3306,
        executable: fake.path,
        freePort: (ports ?? CountingPorts()).next,
        abortTrigger: abortTrigger,
        onLog: onLog,
        configTimeout: configTimeout,
      );
      addTearDown(tunnel.close);
      return tunnel;
    }

    CountingPorts takenPorts() => CountingPorts((_) async => taken.port);

    test('opens on the picked port with the command for the server', () async {
      fake.attemptModes([AttemptMode.ready]);
      const target = SshTarget('ssh.example.com', port: 2222, user: 'alice');
      final port = await pickFreePort();

      final tunnel = await open(
        target: target,
        ports: CountingPorts((_) async => port),
      );

      expect(tunnel.localPort, port);
      expect(fake.attempts, [
        sshCommand(
          target,
          remoteHost: 'db.example.com',
          remotePort: 3306,
          localPort: port,
        ).sublist(1),
      ]);
    });

    test('SystemSshClient runs its executable', () async {
      fake.attemptModes([AttemptMode.ready]);

      final tunnel = await SystemSshClient(executable: fake.path).openTunnel(
        server,
        remoteHost: 'db.example.com',
        remotePort: 3306,
      );
      addTearDown(tunnel.close);

      expect(fake.configArguments, isNotNull);
      expect(fake.attempts, hasLength(1));
    });

    test('passes a DOMAIN\\user through to ssh', () async {
      fake.attemptModes([AttemptMode.ready]);

      await open(target: const SshTarget('ssh.example.com', user: r'CORP\al'));

      expect(fake.attempts.single, containsAllInOrder(['-l', r'CORP\al']));
    });

    test('brackets an IPv6 remote host', () async {
      fake.attemptModes([AttemptMode.ready]);

      final tunnel = await open(remoteHost: '::1');

      expect(
        fake.attempts.single,
        contains('127.0.0.1:${tunnel.localPort}:[::1]:3306'),
      );
    });

    test('passes the log to onLog', () async {
      fake.attemptModes([AttemptMode.ready]);
      final lines = <String>[];

      final tunnel = await open(onLog: lines.add);

      expect(lines, [
        'debug1: Local forwarding listening on 127.0.0.1 port ${tunnel.localPort}.',
        'debug1: Entering interactive session.',
      ]);
    });

    test('logs the command at INFO and the lines at FINE', () async {
      fake.attemptModes([AttemptMode.ready]);
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = level);
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord
          .where((record) => record.loggerName == 'system_ssh')
          .listen(records.add);
      addTearDown(subscription.cancel);
      final port = await pickFreePort();

      await open(ports: CountingPorts((_) async => port));

      final command = sshCommand(
        server,
        remoteHost: 'db.example.com',
        remotePort: 3306,
        localPort: port,
        executable: fake.path,
      );
      expect(
        records.where((record) => record.level == Level.INFO).first.message,
        command.join(' '),
      );
      expect(
        records
            .where((record) => record.level == Level.FINE)
            .map((record) => record.message),
        [
          'debug1: Local forwarding listening on 127.0.0.1 port $port.',
          'debug1: Entering interactive session.',
        ],
      );
    });

    test('close stops ssh', () async {
      fake.attemptModes([AttemptMode.ready]);
      final tunnel = await open();
      final pid = fake.attemptPid(1)!;

      await tunnel.close();

      expect(await stops(pid), isTrue);
    });

    test('does not retry when ssh fails and the port is free', () async {
      fake.attemptModes([AttemptMode.fail, AttemptMode.ready]);
      final ports = CountingPorts();

      await expectLater(
        open(ports: ports),
        throwsA(
          isA<SshTunnelException>().having(
            (exception) => exception.exitCode,
            'exitCode',
            255,
          ),
        ),
      );
      expect(ports.picks, 1);
      expect(fake.attempts, hasLength(1));
    });

    test('retries with a fresh port when the picked one is taken', () async {
      fake.attemptModes([AttemptMode.bindFailure, AttemptMode.ready]);
      final ports = CountingPorts(
        (pick) async => pick == 1 ? taken.port : pickFreePort(),
      );

      final tunnel = await open(ports: ports);

      expect(ports.picks, 2);
      expect(tunnel.localPort, isNot(taken.port));
      expect(fake.attempts, hasLength(2));
    });

    test('gives up after three taken ports', () async {
      fake.attemptModes([AttemptMode.bindFailure]);
      final ports = takenPorts();

      await expectLater(
        open(ports: ports),
        throwsA(
          isA<SshTunnelException>().having(
            (exception) => exception.message,
            'message',
            contains('cannot listen to port: ${taken.port}'),
          ),
        ),
      );
      expect(ports.picks, 3);
      expect(fake.attempts, hasLength(3));
    });

    test(
      "reads sh's exit code 127 as ssh not found, without retrying",
      () async {
        fake.attemptModes([AttemptMode.notFound, AttemptMode.ready]);
        final ports = takenPorts();

        await expectLater(
          open(ports: ports),
          throwsA(isA<SshNotFoundException>()),
        );
        expect(ports.picks, 1);
        expect(fake.attempts, hasLength(1));
      },
    );

    test('reads exit code 127 on a retry as ssh not found', () async {
      fake.attemptModes([AttemptMode.bindFailure, AttemptMode.notFound]);
      final ports = takenPorts();

      await expectLater(
        open(ports: ports),
        throwsA(isA<SshNotFoundException>()),
      );
      expect(ports.picks, 2);
      expect(fake.attempts, hasLength(2));
    });

    test('refuses a config that sets ClearAllForwardings', () async {
      fake
        ..answerConfig(['hostname ssh.example.com', 'clearallforwardings yes'])
        ..attemptModes([AttemptMode.ready]);

      await expectLater(
        open(),
        throwsA(
          isA<SshException>()
              .having(
                (exception) => exception,
                'type',
                isNot(isA<SshTunnelException>()),
              )
              .having(
                (exception) => exception.message,
                'message',
                contains('ClearAllForwardings'),
              ),
        ),
      );
      expect(fake.attempts, isEmpty);
    });

    test('opens when the config has ClearAllForwardings no', () async {
      fake
        ..answerConfig(['clearallforwardings no'])
        ..attemptModes([AttemptMode.ready]);

      await open();

      expect(fake.attempts, hasLength(1));
    });

    test(
      'throws SshTunnelAbortedException when aborted before opening',
      () async {
        fake.attemptModes([AttemptMode.ready]);
        final ports = CountingPorts();

        await expectLater(
          open(abortTrigger: Future.value(), ports: ports),
          throwsA(isA<SshTunnelAbortedException>()),
        );
        expect(ports.picks, 0);
        expect(fake.attempts, isEmpty);
      },
    );

    test(
      'throws SshTunnelAbortedException when aborted while ssh -G runs',
      () async {
        fake
          ..hangOnConfig()
          ..attemptModes([AttemptMode.ready]);
        final abort = Completer<void>();

        final opening = open(abortTrigger: abort.future);
        await fake.configPid;
        abort.complete();

        await expectLater(opening, throwsA(isA<SshTunnelAbortedException>()));
        expect(fake.attempts, isEmpty);
      },
    );

    test('starts no ssh once aborted between attempts', () async {
      fake.attemptModes([AttemptMode.bindFailure]);
      final abort = Completer<void>();
      final ports = CountingPorts((pick) async {
        if (pick == 2) abort.complete();
        return taken.port;
      });

      await expectLater(
        open(abortTrigger: abort.future, ports: ports),
        throwsA(isA<SshTunnelAbortedException>()),
      );
      expect(ports.picks, 2);
      expect(fake.attempts, hasLength(1));
    });

    test('ignores an abortTrigger that fails', () async {
      fake.attemptModes([AttemptMode.ready]);

      await open(abortTrigger: Future.error(StateError('ignored')));

      expect(fake.attempts, hasLength(1));
    });

    test('opens when ssh -G hangs, and stops ssh -G', () async {
      fake
        ..hangOnConfig()
        ..attemptModes([AttemptMode.ready]);

      await open(configTimeout: const Duration(seconds: 1));

      expect(await stops(await fake.configPid), isTrue);
      expect(
        fake.attempts.single,
        containsAll([
          'StrictHostKeyChecking=accept-new',
          'ConnectTimeout=15',
          'ServerAliveInterval=15',
        ]),
      );
    });

    test('leaves host key checking to a config that sets it', () async {
      fake
        ..answerConfig([
          'hostname ssh.example.com',
          'stricthostkeychecking true',
          'connecttimeout none',
          'serveraliveinterval 0',
        ])
        ..attemptModes([AttemptMode.ready]);

      await open();

      final arguments = fake.attempts.single;
      expect(arguments, isNot(contains('StrictHostKeyChecking=accept-new')));
      expect(arguments, contains('ConnectTimeout=15'));
      expect(arguments, contains('ServerAliveInterval=15'));
    });

    test('applies every default when ssh -G fails', () async {
      fake
        ..answerConfig(['stricthostkeychecking true', 'connecttimeout 30'])
        ..failConfig()
        ..attemptModes([AttemptMode.ready]);

      await open();

      expect(
        fake.attempts.single,
        containsAll([
          'StrictHostKeyChecking=accept-new',
          'ConnectTimeout=15',
          'ServerAliveInterval=15',
        ]),
      );
    });
  });
}

String _shown(String character) => character.codeUnitAt(0) < 0x20
    ? '\\x${character.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}'
    : "'$character'";
