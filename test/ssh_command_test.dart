import 'package:system_ssh/src/ssh_command.dart';
import 'package:system_ssh/src/ssh_config.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  const server = SshTarget('ssh.example.com');

  Map<String, String> resolvedConfig({
    String strictHostKeyChecking = 'ask',
    String connectTimeout = 'none',
    String serverAliveInterval = '0',
  }) =>
      parseConfig([
        'host ssh.example.com',
        'user alice',
        'hostname ssh.example.com',
        'port 22',
        'batchmode no',
        'connecttimeout $connectTimeout',
        'controlmaster false',
        'controlpath none',
        'identityfile ~/.ssh/id_ed25519',
        'serveralivecountmax 3',
        'serveraliveinterval $serverAliveInterval',
        'stricthostkeychecking $strictHostKeyChecking',
        'userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2',
      ]);

  List<String> command({
    SshTarget target = server,
    String remoteHost = 'db.example.com',
    Map<String, String> config = const {},
  }) =>
      sshCommand(
        target,
        remoteHost: remoteHost,
        remotePort: 3306,
        localPort: 50000,
        config: config,
      );

  group('destinationArguments', () {
    test('passes port and user, then the host after --', () {
      expect(
        destinationArguments(
          const SshTarget('ssh.example.com', port: 2222, user: 'alice'),
        ),
        [
          ...['-p', '2222'],
          ...['-l', 'alice'],
          '--',
          'ssh.example.com',
        ],
      );
    });

    test('is just -- and the host when port and user are unset', () {
      expect(destinationArguments(server), ['--', 'ssh.example.com']);
    });

    test('passes only the port when the user is unset', () {
      expect(
          destinationArguments(const SshTarget('ssh.example.com', port: 2222)),
          [
            ...['-p', '2222'],
            '--',
            'ssh.example.com',
          ]);
    });

    test('passes only the user when the port is unset', () {
      expect(
          destinationArguments(
              const SshTarget('ssh.example.com', user: 'alice')),
          [
            ...['-l', 'alice'],
            '--',
            'ssh.example.com',
          ]);
    });

    test('keeps a host that looks like an option after --', () {
      expect(destinationArguments(const SshTarget('-oProxyCommand=x')), [
        '--',
        '-oProxyCommand=x',
      ]);
    });
  });

  group('sshCommand', () {
    test('forwards the local port to host and port, destination last', () {
      expect(
        command(
          target: const SshTarget('ssh.example.com', port: 2222, user: 'alice'),
          config: resolvedConfig(
            strictHostKeyChecking: 'yes',
            connectTimeout: '30',
            serverAliveInterval: '60',
          ),
        ),
        [
          'ssh',
          '-nNTv',
          ...['-L', '127.0.0.1:50000:db.example.com:3306'],
          ...['-o', 'ExitOnForwardFailure=yes'],
          ...['-o', 'ControlPath=none'],
          ...['-p', '2222'],
          ...['-l', 'alice'],
          '--',
          'ssh.example.com',
        ],
      );
    });

    test('starts the given ssh executable', () {
      expect(
        sshCommand(
          server,
          remoteHost: 'db.example.com',
          remotePort: 3306,
          localPort: 50000,
          executable: '/opt/openssh/bin/ssh',
        ).first,
        '/opt/openssh/bin/ssh',
      );
    });

    test('applies every default for an empty config', () {
      expect(command(), [
        'ssh',
        '-nNTv',
        ...['-L', '127.0.0.1:50000:db.example.com:3306'],
        ...['-o', 'ExitOnForwardFailure=yes'],
        ...['-o', 'ControlPath=none'],
        ...['-o', 'StrictHostKeyChecking=accept-new'],
        ...['-o', 'ConnectTimeout=15'],
        ...['-o', 'ServerAliveInterval=15'],
        '--',
        'ssh.example.com',
      ]);
    });

    test('applies every default when the config leaves them all unset', () {
      final result = command(config: resolvedConfig());

      expect(
        result,
        containsAllInOrder(['-o', 'StrictHostKeyChecking=accept-new']),
      );
      expect(result, containsAllInOrder(['-o', 'ConnectTimeout=15']));
      expect(result, containsAllInOrder(['-o', 'ServerAliveInterval=15']));
      expect(result.last, 'ssh.example.com');
    });

    test('keeps the fixed options when the config overrides every default', () {
      final result = command(
        config: resolvedConfig(
          strictHostKeyChecking: 'true',
          connectTimeout: '30',
          serverAliveInterval: '60',
        ),
      );

      expect(result.take(2), ['ssh', '-nNTv']);
      expect(
        result,
        containsAllInOrder(['-L', '127.0.0.1:50000:db.example.com:3306']),
      );
      expect(result, containsAllInOrder(['-o', 'ExitOnForwardFailure=yes']));
      expect(result, containsAllInOrder(['-o', 'ControlPath=none']));
      expect(result.last, 'ssh.example.com');
    });

    group('fork after authentication', () {
      test('is turned off when the config turns it on', () {
        expect(
          command(config: {'forkafterauthentication': 'yes'}),
          containsAllInOrder(['-o', 'ForkAfterAuthentication=no']),
        );
      });

      for (final (name, config) in [
        ('no', {'forkafterauthentication': 'no'}),
        ('unset', {'hostname': 'ssh.example.com'}),
        ('empty', <String, String>{}),
      ]) {
        test('is left alone when the config has it $name', () {
          expect(
            command(config: config),
            isNot(contains('ForkAfterAuthentication=no')),
          );
        });
      }
    });

    group('remote host', () {
      test('wraps an IPv6 host in brackets', () {
        expect(
          command(remoteHost: '::1'),
          containsAllInOrder(['-L', '127.0.0.1:50000:[::1]:3306']),
        );
      });

      test('leaves an already bracketed IPv6 host alone', () {
        expect(
          command(remoteHost: '[fd00::5]'),
          containsAllInOrder(['-L', '127.0.0.1:50000:[fd00::5]:3306']),
        );
      });

      test('leaves an IPv4 host unbracketed', () {
        expect(
          command(remoteHost: '10.0.0.5'),
          containsAllInOrder(['-L', '127.0.0.1:50000:10.0.0.5:3306']),
        );
      });
    });

    group('host keys', () {
      test("accepts a new host key for ssh's default ask", () {
        expect(
          command(config: resolvedConfig()),
          containsAllInOrder(['-o', 'StrictHostKeyChecking=accept-new']),
        );
      });

      for (final value in ['yes', 'true', 'false', 'accept-new', 'off']) {
        test('leaves host key checking to ssh when the config sets $value', () {
          expect(
            command(config: resolvedConfig(strictHostKeyChecking: value)),
            isNot(contains('StrictHostKeyChecking=accept-new')),
          );
        });
      }
    });

    group('connect timeout', () {
      test('sets 15 seconds when the config has none', () {
        expect(
          command(config: resolvedConfig()),
          containsAllInOrder(['-o', 'ConnectTimeout=15']),
        );
      });

      test('leaves a configured timeout alone', () {
        expect(
          command(config: resolvedConfig(connectTimeout: '30')),
          isNot(contains('ConnectTimeout=15')),
        );
      });
    });

    group('server alive interval', () {
      test('sets 15 seconds when the config has 0', () {
        expect(
          command(config: resolvedConfig()),
          containsAllInOrder(['-o', 'ServerAliveInterval=15']),
        );
      });

      for (final value in ['60', '10']) {
        test('leaves a configured interval of $value alone', () {
          expect(
            command(config: resolvedConfig(serverAliveInterval: value)),
            isNot(contains('ServerAliveInterval=15')),
          );
        });
      }
    });
  });

  group('bracketIPv6', () {
    for (final (host, bracketed) in [
      ('::1', '[::1]'),
      ('fd00::5', '[fd00::5]'),
      ('[fd00::5]', '[fd00::5]'),
      ('10.0.0.5', '10.0.0.5'),
      ('db.example.com', 'db.example.com'),
      ('', ''),
    ]) {
      test("makes '$host' '$bracketed'", () {
        expect(bracketIPv6(host), bracketed);
      });
    }
  });
}
