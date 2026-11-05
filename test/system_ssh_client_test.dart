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

  test('SystemSshClient runs ssh by default, in the inherited environment', () {
    const client = SystemSshClient();

    expect(client.executable, 'ssh');
    expect(client.environment, isEmpty);
  });

  test('throws SshNotFoundException when ssh is missing', () async {
    await expectLater(
      openSystemForward(
        server,
        forward: localForwardTo('db.example.com', 3306),
        executable: '/nonexistent/ssh',
      ),
      throwsA(isA<SshNotFoundException>()),
    );
  });

  group('validation', () {
    Future<SshTunnel> open({
      SshTarget target = server,
      String remoteHost = 'db.example.com',
      int? localPort,
    }) async =>
        openSystemForward(
          target,
          forward: localForwardTo(remoteHost, 3306),
          localPort: localPort,
          executable: '/nonexistent/ssh',
          portIsFree: (_) async => true,
        );

    Matcher throwsInvalid(String name, Object value) => throwsA(
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

    for (final port in [-1, 0, 65536]) {
      test('rejects local port $port', () async {
        await expectLater(
          open(localPort: port),
          throwsInvalid('localPort', port),
        );
      });
    }

    for (final port in [1, 65535]) {
      test('accepts local port $port', () async {
        await expectLater(
          open(localPort: port),
          throwsA(isA<SshNotFoundException>()),
        );
      });
    }

    group('of a SOCKS proxy', () {
      Future<SshTunnel> openProxy({
        SshTarget target = server,
        int? localPort,
      }) async =>
          openSystemForward(
            target,
            forward: dynamicForward,
            localPort: localPort,
            executable: '/nonexistent/ssh',
            portIsFree: (_) async => true,
          );

      test('rejects a server host starting with -', () async {
        await expectLater(
          openProxy(target: const SshTarget('-oProxyCommand=false')),
          throwsInvalid('server', '-oProxyCommand=false'),
        );
      });

      for (final character in [...unsafe, r'\']) {
        final host = 'ssh${character}example.com';

        test('rejects a server host holding ${_shown(character)}', () async {
          await expectLater(
            openProxy(target: SshTarget(host)),
            throwsInvalid('server', host),
          );
        });
      }

      for (final character in unsafe) {
        final user = 'al${character}ice';

        test('rejects a user holding ${_shown(character)}', () async {
          await expectLater(
            openProxy(target: SshTarget('ssh.example.com', user: user)),
            throwsInvalid('server', user),
          );
        });
      }

      for (final port in [-1, 0, 65536]) {
        test('rejects local port $port', () async {
          await expectLater(
            openProxy(localPort: port),
            throwsInvalid('localPort', port),
          );
        });
      }

      for (final port in [1, 65535]) {
        test('accepts local port $port', () async {
          await expectLater(
            openProxy(localPort: port),
            throwsA(isA<SshNotFoundException>()),
          );
        });
      }
    });
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
      int? localPort,
      CountingPorts? ports,
      Future<bool> Function(int port) portIsFree = isPortFree,
      Future<void>? abortTrigger,
      void Function(SshLog log)? onLog,
      Duration configTimeout = const Duration(seconds: 5),
      String? executable,
      Map<String, String> environment = const {},
    }) async {
      final tunnel = await openSystemForward(
        target,
        forward: localForwardTo(remoteHost, 3306),
        localPort: localPort,
        executable: executable ?? fake.path,
        environment: environment,
        freePort: (ports ?? CountingPorts()).next,
        portIsFree: portIsFree,
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
          forward: localForward(port,
              remoteHost: 'db.example.com', remotePort: 3306),
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

    test('SystemSshClient runs ssh in its environment', () async {
      fake.attemptModes([AttemptMode.ready]);

      final tunnel = await SystemSshClient(
        executable: fake.path,
        environment: const {'SYSTEM_SSH_ADDED': 'added'},
      ).openTunnel(server, remoteHost: 'db.example.com', remotePort: 3306);
      addTearDown(tunnel.close);

      expect(fake.configEnvironment, containsPair('SYSTEM_SSH_ADDED', 'added'));
      expect(
        fake.attemptEnvironments.single,
        containsPair('SYSTEM_SSH_ADDED', 'added'),
      );
    });

    test('adds the environment to the inherited one in every attempt',
        () async {
      fake.attemptModes([AttemptMode.bindFailure, AttemptMode.ready]);
      final ports = CountingPorts(
        (pick) async => pick == 1 ? taken.port : pickFreePort(),
      );
      const environment = {
        'SYSTEM_SSH_ADDED': 'one\ntwo',
        'SSH_AUTH_SOCK': '/tmp/agent.sock',
      };
      final inherited = Platform.isWindows ? 'SystemRoot' : 'HOME';

      await open(ports: ports, environment: environment);

      for (final recorded in [
        fake.configEnvironment!,
        ...fake.attemptEnvironments,
      ]) {
        expect(recorded, containsPair('SYSTEM_SSH_ADDED', 'one\ntwo'));
        expect(recorded, containsPair('SSH_AUTH_SOCK', '/tmp/agent.sock'));
        // Windows variable names are case-insensitive, and the child may spell them in capitals.
        expect(
          {
            for (final entry in recorded.entries)
              entry.key.toUpperCase(): entry.value,
          },
          containsPair(
            inherited.toUpperCase(),
            Platform.environment[inherited],
          ),
        );
      }
      expect(fake.attemptEnvironments, hasLength(2));
    });

    test('finds a bare executable on the PATH the environment sets', () async {
      fake.attemptModes([AttemptMode.ready]);

      await open(
        executable: 'ssh',
        environment: {
          'PATH': [fake.directory, Platform.environment['PATH']]
              .join(Platform.isWindows ? ';' : ':'),
        },
      );

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

      final tunnel = await open(onLog: (log) => lines.add(log.line));

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
        forward:
            localForward(port, remoteHost: 'db.example.com', remotePort: 3306),
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

    group('with a fixed local port', () {
      Matcher throwsPortInUse(int port) => throwsA(
            isA<SshPortInUseException>()
                .having((exception) => exception.port, 'port', port),
          );

      test('forwards it without picking one', () async {
        fake.attemptModes([AttemptMode.ready]);
        final port = await pickFreePort();
        final ports = CountingPorts();

        final tunnel = await open(localPort: port, ports: ports);

        expect(tunnel.localPort, port);
        expect(ports.picks, 0);
        expect(fake.attempts, [
          sshCommand(
            server,
            forward: localForward(port,
                remoteHost: 'db.example.com', remotePort: 3306),
          ).sublist(1),
        ]);
      });

      test('SystemSshClient passes it to ssh', () async {
        fake.attemptModes([AttemptMode.ready]);
        final port = await pickFreePort();

        final tunnel = await SystemSshClient(executable: fake.path).openTunnel(
          server,
          remoteHost: 'db.example.com',
          remotePort: 3306,
          localPort: port,
        );
        addTearDown(tunnel.close);

        expect(tunnel.localPort, port);
        expect(
          fake.attempts.single,
          contains('127.0.0.1:$port:db.example.com:3306'),
        );
      });

      test('fails without starting ssh when it is taken', () async {
        fake.attemptModes([AttemptMode.ready]);
        final ports = CountingPorts();

        await expectLater(
          open(localPort: taken.port, ports: ports),
          throwsPortInUse(taken.port),
        );
        expect(ports.picks, 0);
        expect(fake.attempts, isEmpty);
      });

      test('reads a bind failure as taken once the port is', () async {
        fake.attemptModes([AttemptMode.bindFailure, AttemptMode.ready]);
        var checks = 0;

        await expectLater(
          open(
            localPort: taken.port,
            portIsFree: (port) async => ++checks == 1 || await isPortFree(port),
          ),
          throwsPortInUse(taken.port),
        );
        expect(checks, 2);
        expect(fake.attempts, hasLength(1));
      });

      test('rethrows an ssh failure while it is free, without retrying',
          () async {
        fake.attemptModes([AttemptMode.fail, AttemptMode.ready]);
        final ports = CountingPorts();

        await expectLater(
          open(localPort: await pickFreePort(), ports: ports),
          throwsA(
            isA<SshTunnelException>().having(
              (exception) => exception.exitCode,
              'exitCode',
              255,
            ),
          ),
        );
        expect(ports.picks, 0);
        expect(fake.attempts, hasLength(1));
      });

      test("reads sh's exit code 127 as ssh not found", () async {
        fake.attemptModes([AttemptMode.notFound]);

        await expectLater(
          open(localPort: await pickFreePort()),
          throwsA(isA<SshNotFoundException>()),
        );
        expect(fake.attempts, hasLength(1));
      });

      test('throws SshTunnelAbortedException when aborted first', () async {
        fake.attemptModes([AttemptMode.ready]);

        await expectLater(
          open(localPort: await pickFreePort(), abortTrigger: Future.value()),
          throwsA(isA<SshTunnelAbortedException>()),
        );
        expect(fake.attempts, isEmpty);
      });
    });

    group('SOCKS proxy', () {
      Future<SshTunnel> openProxy({
        SshTarget target = server,
        int? localPort,
        CountingPorts? ports,
        Future<bool> Function(int port) portIsFree = isPortFree,
        Future<void>? abortTrigger,
        void Function(SshLog log)? onLog,
      }) async {
        final tunnel = await openSystemForward(
          target,
          forward: dynamicForward,
          localPort: localPort,
          executable: fake.path,
          freePort: (ports ?? CountingPorts()).next,
          portIsFree: portIsFree,
          abortTrigger: abortTrigger,
          onLog: onLog,
        );
        addTearDown(tunnel.close);
        return tunnel;
      }

      Matcher throwsPortInUse(int port) => throwsA(
            isA<SshPortInUseException>()
                .having((exception) => exception.port, 'port', port),
          );

      test('opens on the picked port with the -D command', () async {
        fake.attemptModes([AttemptMode.ready]);
        const target = SshTarget('ssh.example.com', port: 2222, user: 'alice');
        final port = await pickFreePort();
        final ports = CountingPorts((_) async => port);

        final proxy = await openProxy(target: target, ports: ports);

        expect(proxy.localPort, port);
        expect(ports.picks, 1);
        expect(fake.attempts, [
          [
            '-nNTv',
            ...['-D', '127.0.0.1:$port'],
            ...['-o', 'ExitOnForwardFailure=yes'],
            ...['-o', 'ControlPath=none'],
            ...['-o', 'BatchMode=yes'],
            ...['-o', 'StrictHostKeyChecking=accept-new'],
            ...['-o', 'ConnectTimeout=15'],
            ...['-o', 'ServerAliveInterval=15'],
            ...['-p', '2222'],
            ...['-l', 'alice'],
            '--',
            'ssh.example.com',
          ],
        ]);
      });

      test('passes the log to onLog', () async {
        fake.attemptModes([AttemptMode.ready]);
        final lines = <String>[];

        final proxy = await openProxy(onLog: (log) => lines.add(log.line));

        expect(lines, [
          'debug1: Local forwarding listening on 127.0.0.1 port ${proxy.localPort}.',
          'debug1: Entering interactive session.',
        ]);
      });

      test('close stops ssh', () async {
        fake.attemptModes([AttemptMode.ready]);
        final proxy = await openProxy();
        final pid = fake.attemptPid(1)!;

        await proxy.close();

        expect(await stops(pid), isTrue);
      });

      test('retries with a fresh port when the picked one is taken', () async {
        fake.attemptModes([AttemptMode.bindFailure, AttemptMode.ready]);
        final ports = CountingPorts(
          (pick) async => pick == 1 ? taken.port : pickFreePort(),
        );

        final proxy = await openProxy(ports: ports);

        expect(ports.picks, 2);
        expect(proxy.localPort, isNot(taken.port));
        expect(fake.attempts, hasLength(2));
      });

      test('does not retry when ssh fails and the port is free', () async {
        fake.attemptModes([AttemptMode.fail, AttemptMode.ready]);
        final ports = CountingPorts();

        await expectLater(
          openProxy(ports: ports),
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

      test("reads sh's exit code 127 as ssh not found", () async {
        fake.attemptModes([AttemptMode.notFound, AttemptMode.ready]);

        await expectLater(
          openProxy(),
          throwsA(isA<SshNotFoundException>()),
        );
        expect(fake.attempts, hasLength(1));
      });

      test('serves a fixed local port without picking one', () async {
        fake.attemptModes([AttemptMode.ready]);
        final port = await pickFreePort();
        final ports = CountingPorts();

        final proxy = await openProxy(localPort: port, ports: ports);

        expect(proxy.localPort, port);
        expect(ports.picks, 0);
        expect(
          fake.attempts.single,
          containsAllInOrder(['-D', '127.0.0.1:$port']),
        );
      });

      test('fails without starting ssh when the fixed port is taken', () async {
        fake.attemptModes([AttemptMode.ready]);

        await expectLater(
          openProxy(localPort: taken.port),
          throwsPortInUse(taken.port),
        );
        expect(fake.attempts, isEmpty);
      });

      test('reads a bind failure as taken once the fixed port is', () async {
        fake.attemptModes([AttemptMode.bindFailure, AttemptMode.ready]);
        var checks = 0;

        await expectLater(
          openProxy(
            localPort: taken.port,
            portIsFree: (port) async => ++checks == 1 || await isPortFree(port),
          ),
          throwsPortInUse(taken.port),
        );
        expect(checks, 2);
        expect(fake.attempts, hasLength(1));
      });

      test('rethrows an ssh failure while the fixed port is free', () async {
        fake.attemptModes([AttemptMode.fail, AttemptMode.ready]);

        await expectLater(
          openProxy(localPort: await pickFreePort()),
          throwsA(
            isA<SshTunnelException>().having(
              (exception) => exception.exitCode,
              'exitCode',
              255,
            ),
          ),
        );
        expect(fake.attempts, hasLength(1));
      });

      test('throws SshTunnelAbortedException when aborted first', () async {
        fake.attemptModes([AttemptMode.ready]);
        final ports = CountingPorts();

        await expectLater(
          openProxy(abortTrigger: Future.value(), ports: ports),
          throwsA(isA<SshTunnelAbortedException>()),
        );
        expect(ports.picks, 0);
        expect(fake.attempts, isEmpty);
      });

      test('refuses a config that sets ClearAllForwardings', () async {
        fake
          ..answerConfig(['clearallforwardings yes'])
          ..attemptModes([AttemptMode.ready]);

        await expectLater(
          openProxy(),
          throwsA(
            isA<SshException>().having(
              (exception) => exception.message,
              'message',
              contains('ClearAllForwardings'),
            ),
          ),
        );
        expect(fake.attempts, isEmpty);
      });

      test('SystemSshClient opens it in its environment', () async {
        fake.attemptModes([AttemptMode.ready]);
        final port = await pickFreePort();

        final proxy = await SystemSshClient(
          executable: fake.path,
          environment: const {'SYSTEM_SSH_ADDED': 'added'},
        ).openSocksProxy(server, localPort: port);
        addTearDown(proxy.close);

        expect(proxy.localPort, port);
        expect(
          fake.attempts.single,
          containsAllInOrder(['-D', '127.0.0.1:$port']),
        );
        expect(
          fake.configEnvironment,
          containsPair('SYSTEM_SSH_ADDED', 'added'),
        );
        expect(
          fake.attemptEnvironments.single,
          containsPair('SYSTEM_SSH_ADDED', 'added'),
        );
      });

      test("SystemSshClient's environment wins over the login shell's",
          () async {
        fake.attemptModes([AttemptMode.ready]);

        final proxy = await SystemSshClient(
          executable: fake.path,
          loginShell: true,
          environment: const {'HOME': '/system_ssh/home'},
        ).openSocksProxy(server);
        addTearDown(proxy.close);

        expect(
          fake.attemptEnvironments.single,
          containsPair('HOME', '/system_ssh/home'),
        );
      });
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
          'BatchMode=yes',
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
          'BatchMode=yes',
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
