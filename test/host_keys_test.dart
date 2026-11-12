import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:system_ssh/src/host_keys.dart';
import 'package:system_ssh/src/ssh_command.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';
import 'fakes/fakes.dart';

void main() {
  const server = SshTarget('ssh.example.com', port: 2222);
  const hostKey = SshHostKey(
    host: fakeHostKeyName,
    type: 'ED25519',
    fingerprint: fakeHostKeyFingerprint,
  );
  const askConfig = {
    'hostname': 'ssh.example.com',
    'port': '2222',
    'stricthostkeychecking': 'ask',
  };

  const unknownLog = [
    'debug1: Connecting to ssh.example.com port 2222.',
    'debug1: Server host key: ssh-ed25519 $fakeHostKeyFingerprint',
    'No ED25519 host key is known for $fakeHostKeyName and you have requested strict checking.',
    'Host key verification failed.',
  ];
  const changedLog = [
    'debug1: Server host key: ssh-ed25519 $otherHostKeyFingerprint',
    '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @',
    'The fingerprint for the ED25519 key sent by the remote host is',
    '$otherHostKeyFingerprint.',
    'Offending ED25519 key in /home/user/.ssh/known_hosts:3',
    'Host key for $fakeHostKeyName has changed and you have requested strict checking.',
    'Host key verification failed.',
  ];

  SshTunnelException failure(List<String> log) =>
      SshTunnelException(log.last, log: log, exitCode: 255, isPermanent: true);

  group('knownHostsName', () {
    for (final (config, name) in [
      ({'hostname': 'ssh.example.com', 'port': '22'}, 'ssh.example.com'),
      ({'hostname': 'SSH.example.com', 'port': '2222'}, fakeHostKeyName),
      ({'hostname': '::1', 'port': '2222'}, '[::1]:2222'),
      (
        {
          'hostname': 'ssh.example.com',
          'port': '2222',
          'hostkeyalias': 'bastion'
        },
        'bastion',
      ),
      (<String, String>{}, null),
    ]) {
      test('is $name for $config', () {
        expect(knownHostsName(config), name);
      });
    }
  });

  group('hostKeyFailure', () {
    test('reads an unknown key where the config asks', () {
      final result = hostKeyFailure(failure(unknownLog), askConfig);

      expect(
        result,
        isA<SshUnknownHostKeyException>()
            .having((exception) => exception.hostKey, 'hostKey', hostKey)
            .having((exception) => exception.log, 'log', unknownLog)
            .having((exception) => exception.exitCode, 'exitCode', 255)
            .having((exception) => exception.isPermanent, 'isPermanent', true),
      );
      expect(
        result!.message,
        allOf(contains(fakeHostKeyName), contains(fakeHostKeyFingerprint)),
      );
    });

    test('reads an unknown key when the config could not be read', () {
      expect(
        hostKeyFailure(failure(unknownLog), const {}),
        isA<SshUnknownHostKeyException>(),
      );
    });

    for (final value in ['yes', 'true', 'accept-new', 'no']) {
      test('leaves an unknown key alone where the config sets $value', () {
        expect(
          hostKeyFailure(
            failure(unknownLog),
            {...askConfig, 'stricthostkeychecking': value},
          ),
          isNull,
        );
      });
    }

    test("leaves another host's unknown key alone, as a ProxyJump's is", () {
      expect(
        hostKeyFailure(failure(unknownLog), {
          ...askConfig,
          'hostname': 'server.internal',
        }),
        isNull,
      );
    });

    test('takes the fingerprint ssh logged last before the unknown key', () {
      final log = [
        'debug1: Server host key: ssh-ed25519 $otherHostKeyFingerprint',
        "debug1: Host 'jump.example.com' is known and matches the ED25519 host key.",
        ...unknownLog,
      ];

      expect(
        (hostKeyFailure(failure(log), askConfig)! as SshUnknownHostKeyException)
            .hostKey,
        hostKey,
      );
    });

    test('reads a changed key whatever the config sets or ssh says', () {
      final newerLog = [
        for (final line in changedLog)
          line.replaceFirst('Host key for', 'ED25519 host key for'),
      ];
      for (final (config, log) in [
        (askConfig, changedLog),
        ({...askConfig, 'stricthostkeychecking': 'yes'}, changedLog),
        (askConfig, newerLog),
      ]) {
        expect(
          hostKeyFailure(failure(log), config),
          isA<SshHostKeyChangedException>().having(
            (exception) => exception.hostKey,
            'hostKey',
            const SshHostKey(
              host: fakeHostKeyName,
              type: 'ED25519',
              fingerprint: otherHostKeyFingerprint,
            ),
          ),
        );
      }
    });

    test("takes the target's unknown key over a jump host's banner", () {
      final log = [
        // A ProxyJump host's banner, printed first, can say anything.
        'debug1: Server host key: ssh-ed25519 $otherHostKeyFingerprint',
        'No ED25519 host key is known for $fakeHostKeyName and you have requested strict checking.',
        ...unknownLog,
      ];

      expect(
        (hostKeyFailure(failure(log), askConfig)! as SshUnknownHostKeyException)
            .hostKey,
        hostKey,
      );
    });

    test("is null for a server's banner that only says a key changed", () {
      for (final log in [
        // ssh never said it gave up on the key.
        changedLog.where((line) => !line.startsWith('Host key verification')),
        // It logged in to the server after the banner.
        [
          ...changedLog,
          'Authenticated to ssh.example.com ([10.0.0.1]:2222) using "publickey".',
        ],
      ]) {
        expect(hostKeyFailure(failure(log.toList()), askConfig), isNull);
      }
    });

    test("leaves a ProxyJump host's changed key alone", () {
      expect(
        hostKeyFailure(failure(changedLog), {
          ...askConfig,
          'hostname': 'server.internal',
        }),
        isNull,
      );
    });

    test('is null for any other failure', () {
      expect(
        hostKeyFailure(
          failure(['user@ssh.example.com: Permission denied (publickey).']),
          askConfig,
        ),
        isNull,
      );
    });
  });

  group('userKnownHostsFile', () {
    const environment = {'HOME': '/home/alice', 'USER': 'alice'};

    for (final (files, path) in [
      (null, '/home/alice/.ssh/known_hosts'),
      (
        '/home/alice/.ssh/known_hosts /home/alice/.ssh/known_hosts2',
        '/home/alice/.ssh/known_hosts',
      ),
      ('~/.ssh/kh ~/.ssh/kh2', '/home/alice/.ssh/kh'),
      ('/home/alice/my keys/kh /etc/kh', '/home/alice/my keys/kh'),
      ('%d/.ssh/hosts_%u', '/home/alice/.ssh/hosts_alice'),
      ('/home/alice/100%%', '/home/alice/100%'),
      ('C:/Users/alice/.ssh/known_hosts', 'C:/Users/alice/.ssh/known_hosts'),
      (
        r'C:\Users\alice\.ssh\known_hosts C:\kh2',
        r'C:\Users\alice\.ssh\known_hosts'
      ),
    ]) {
      test('is $path for $files', () {
        expect(
          userKnownHostsFile(
            {if (files != null) 'userknownhostsfile': files},
            environment: environment,
          ).path,
          path,
        );
      });
    }

    test('fills in an environment variable', () {
      expect(
        userKnownHostsFile(
          {'userknownhostsfile': r'${KNOWN}/known_hosts'},
          environment: {...environment, 'KNOWN': '/srv/ssh'},
        ).path,
        '/srv/ssh/known_hosts',
      );
    });

    for (final files in [
      r'${SYSTEM_SSH_NOT_SET}/known_hosts',
      '/dev/null',
      'relative/known_hosts',
    ]) {
      test('refuses $files, which ssh would not read back', () {
        expect(
          () => userKnownHostsFile(
            {'userknownhostsfile': files},
            environment: environment,
          ),
          throwsA(isA<SshConfigException>()),
        );
      });
    }

    test('refuses UserKnownHostsFile none', () {
      expect(
        () => userKnownHostsFile(
          {'userknownhostsfile': 'none'},
          environment: environment,
        ),
        throwsA(isA<SshConfigException>()),
      );
    });

    test("refuses a file named by a token it can't fill in", () {
      expect(
        () => userKnownHostsFile(
          {'userknownhostsfile': '~/.ssh/known_hosts_%h'},
          environment: environment,
        ),
        throwsA(isA<SshConfigException>()),
      );
    });
  });

  group('fingerprintOf', () {
    final blob = base64.decode(fakeHostKeyEntry.split(' ').last);

    test('is what ssh-keygen -lf prints', () {
      expect(fingerprintOf(blob), fakeHostKeyFingerprint);
      expect(
        fingerprintOf(blob, like: 'MD5:aa'),
        'MD5:ec:f9:c7:64:19:bc:ea:ce:7b:99:65:15:c5:ee:9d:1c',
      );
    });

    test('names a key type as ssh does', () {
      expect(
        [
          'ssh-ed25519',
          'ssh-rsa',
          'ecdsa-sha2-nistp384',
          'sk-ssh-ed25519@openssh.com',
        ].map(keyTypeName),
        ['ED25519', 'RSA', 'ECDSA', 'ED25519-SK'],
      );
    });
  });

  test('hostKeyCommand reads the key without logging in or forwarding', () {
    expect(
      hostKeyCommand(
        server,
        knownHosts: '/tmp/read/known_hosts',
        config: const {
          ...askConfig,
          'connecttimeout': 'none',
          'userknownhostsfile': '/home/alice/.ssh/known_hosts /etc/kh2',
        },
      ),
      [
        'ssh',
        '-nNTv',
        ...['-o', 'BatchMode=yes'],
        ...['-o', 'StrictHostKeyChecking=accept-new'],
        ...[
          '-o',
          'UserKnownHostsFile="/tmp/read/known_hosts" "/home/alice/.ssh/known_hosts" "/etc/kh2"',
        ],
        ...['-o', 'PreferredAuthentications=none'],
        ...['-o', 'ClearAllForwardings=yes'],
        ...['-o', 'PermitLocalCommand=no'],
        ...['-o', 'ControlPath=none'],
        ...['-o', 'ConnectTimeout=15'],
        ...destinationArguments(server),
      ],
    );
  });

  group('with a fake ssh', () {
    late FakeSsh fake;
    late SystemSshClient client;

    setUp(() async {
      fake = await FakeSsh.create();
      client = SystemSshClient(executable: fake.path);
      fake.answerConfig([
        'hostname ssh.example.com',
        'port 2222',
        'stricthostkeychecking ask',
        'userknownhostsfile ${fake.knownHosts.path}',
      ]);
    });

    Future<SshTunnel> open([SystemSshClient? through]) async {
      final tunnel = await (through ?? client).openTunnel(
        server,
        remoteHost: 'db.example.com',
        remotePort: 3306,
      );
      addTearDown(tunnel.close);
      return tunnel;
    }

    test('an unknown key throws, then opens once trusted', () async {
      fake.hostKeyMode(HostKeyMode.unknown);

      final exception = await open().then<Object?>(
        (_) => null,
        onError: (Object exception) => exception,
      );
      expect(
        exception,
        isA<SshUnknownHostKeyException>()
            .having((exception) => exception.hostKey, 'hostKey', hostKey),
      );
      expect(fake.knownHosts.existsSync(), isFalse);

      await client.trustHostKey(server, hostKey);

      expect(fake.knownHosts.readAsStringSync(), '$fakeHostKeyEntry\n');
      expect(await open(), isA<SshTunnel>());
    });

    for (final (kind, start) in [
      (
        'a SOCKS proxy',
        (SystemSshClient client) => client.openSocksProxy(server),
      ),
      (
        'a remote tunnel',
        (SystemSshClient client) =>
            client.openRemoteTunnel(server, localPort: 3000),
      ),
      (
        'a shared connection',
        (SystemSshClient client) => SystemSshClient(
              executable: client.executable,
              shareConnections: true,
            ).openTunnel(server, remoteHost: 'db.example.com', remotePort: 1),
      ),
    ]) {
      test('$kind throws for an unknown key too', () async {
        fake.hostKeyMode(HostKeyMode.unknown);

        await expectLater(
          start(client),
          throwsA(isA<SshUnknownHostKeyException>()),
        );
      }, testOn: kind == 'a shared connection' ? '!windows' : null);
    }

    test('a config that sets StrictHostKeyChecking yes gets ssh\'s failure',
        () async {
      fake
        ..answerConfig([
          'hostname ssh.example.com',
          'port 2222',
          'stricthostkeychecking true',
        ])
        ..hostKeyMode(HostKeyMode.unknown);

      await expectLater(
        open(),
        throwsA(
          isA<SshTunnelException>()
              .having((exception) => exception, 'type',
                  isNot(isA<SshUnknownHostKeyException>()))
              .having(
                  (exception) => exception.isPermanent, 'isPermanent', isTrue),
        ),
      );
    });

    test('a changed key throws SshHostKeyChangedException', () async {
      fake.hostKeyMode(HostKeyMode.changed);

      await expectLater(
        open(),
        throwsA(
          isA<SshHostKeyChangedException>().having(
            (exception) => exception.hostKey.fingerprint,
            'fingerprint',
            fakeHostKeyFingerprint,
          ),
        ),
      );
    });

    test('an unknown key at a fixed port is not a port in use', () async {
      fake.hostKeyMode(HostKeyMode.unknown);
      var checks = 0;

      await expectLater(
        openSystemForward(
          server,
          forward: localForwardTo('db.example.com', 3306),
          localPort: 50000,
          // Free when checked first, taken by the time ssh fails.
          portIsFree: (_) async => checks++ == 0,
          executable: fake.path,
        ),
        throwsA(isA<SshUnknownHostKeyException>()),
      );
    });

    test("an unknown ProxyJump host is ssh's failure, not one to trust",
        () async {
      fake.hostKeyMode(HostKeyMode.jumpUnknown);

      await expectLater(
        open(),
        throwsA(
          isA<SshTunnelException>()
              .having((exception) => exception, 'type',
                  isNot(isA<SshUnknownHostKeyException>()))
              .having((exception) => exception.message, 'message',
                  contains('Host key verification failed')),
        ),
      );
    });

    group('trustHostKey', () {
      test('reads the key with the command for the server', () async {
        await client.trustHostKey(server, hostKey);

        final arguments = fake.trustArguments!;
        expect(arguments,
            containsAllInOrder(['-o', 'StrictHostKeyChecking=accept-new']));
        expect(arguments, contains('PreferredAuthentications=none'));
        expect(
          arguments.firstWhere(
            (argument) => argument.startsWith('UserKnownHostsFile='),
          ),
          endsWith(' "${fake.knownHosts.path.replaceAll(r'\', '/')}"'),
        );
        expect(arguments.sublist(arguments.length - 4),
            ['-p', '2222', '--', 'ssh.example.com']);
        final readInto = RegExp('"([^"]+)"').firstMatch(
          arguments.firstWhere(
            (argument) => argument.startsWith('UserKnownHostsFile='),
          ),
        )![1]!;
        expect(File(readInto).parent.existsSync(), isFalse);
      });

      test('adds the key after what known_hosts already holds', () async {
        fake.knownHosts.writeAsStringSync('other.example.com ssh-ed25519 AAAA');

        await client.trustHostKey(server, hostKey);

        expect(
          fake.knownHosts.readAsStringSync(),
          'other.example.com ssh-ed25519 AAAA\n$fakeHostKeyEntry\n',
        );
      });

      test('writes nothing when ssh got another key than the one checked',
          () async {
        // The fake's log names the checked key, as a server's banner can.
        fake.trustMode(TrustMode.addsOther);

        await expectLater(
          client.trustHostKey(server, hostKey),
          throwsA(
            isA<SshUnknownHostKeyException>().having(
              (exception) => exception.hostKey.fingerprint,
              'fingerprint',
              otherHostKeyFingerprint,
            ),
          ),
        );
        expect(fake.knownHosts.existsSync(), isFalse);
      });

      test('adds every entry ssh wrote for the key, hashed or by address',
          () async {
        fake.trustMode(TrustMode.checkHostIp);

        await client.trustHostKey(server, hostKey);

        expect(
          fake.knownHosts.readAsStringSync(),
          checkHostIpEntries.map((entry) => '$entry\n').join(),
        );
      });

      test('adds the key once past a ProxyJump host it logged in to', () async {
        fake.trustMode(TrustMode.viaJump);

        await client.trustHostKey(server, hostKey);

        expect(fake.knownHosts.readAsStringSync(), '$fakeHostKeyEntry\n');
      });

      test("says why when only a ProxyJump host's key was known", () async {
        fake.trustMode(TrustMode.jumpOnly);

        await expectLater(
          client.trustHostKey(server, hostKey),
          throwsA(
            isA<SshTunnelException>().having(
              (exception) => exception.message,
              'message',
              contains('Connection closed'),
            ),
          ),
        );
        expect(fake.knownHosts.existsSync(), isFalse);
      });

      test('adds the key from a server that lets ssh log in', () async {
        fake.trustMode(TrustMode.authenticates);

        await client
            .trustHostKey(server, hostKey)
            .timeout(const Duration(seconds: 10));

        expect(fake.knownHosts.readAsStringSync(), '$fakeHostKeyEntry\n');
      });

      test('makes a missing ~/.ssh for the user alone', () async {
        final knownHosts = File('${fake.directory}/home/.ssh/known_hosts');
        fake.answerConfig([
          'hostname ssh.example.com',
          'port 2222',
          'stricthostkeychecking ask',
          'userknownhostsfile ${knownHosts.path}',
        ]);

        await client.trustHostKey(server, hostKey);

        expect(knownHosts.readAsStringSync(), '$fakeHostKeyEntry\n');
        if (!Platform.isWindows) {
          expect(knownHosts.parent.statSync().mode & 0x1ff, 0x1c0);
        }
      });

      test('writes nothing when known_hosts holds another key', () async {
        fake.trustMode(TrustMode.changed);

        await expectLater(
          client.trustHostKey(server, hostKey),
          throwsA(isA<SshHostKeyChangedException>()),
        );
        expect(fake.knownHosts.existsSync(), isFalse);
      });

      test('writes nothing more for a key that is already known', () async {
        fake.trustMode(TrustMode.known);

        await client.trustHostKey(server, hostKey);

        expect(fake.knownHosts.existsSync(), isFalse);
      });

      test("says why when ssh can't reach the server", () async {
        fake.trustMode(TrustMode.unreachable);

        await expectLater(
          client.trustHostKey(server, hostKey),
          throwsA(
            isA<SshTunnelException>()
                .having((exception) => exception.message, 'message',
                    contains('Connection refused'))
                .having((exception) => exception.isPermanent, 'isPermanent',
                    isFalse),
          ),
        );
        expect(fake.knownHosts.existsSync(), isFalse);
      });

      test('writes nothing once aborted', () async {
        await expectLater(
          client.trustHostKey(server, hostKey, abortTrigger: Future.value()),
          throwsA(isA<SshTunnelAbortedException>()),
        );
        expect(fake.trustArguments, isNull);
        expect(fake.knownHosts.existsSync(), isFalse);
      });

      test('stops reading the key when aborted', () async {
        fake.trustMode(TrustMode.hang);
        final abort = Completer<void>();

        final trusting =
            client.trustHostKey(server, hostKey, abortTrigger: abort.future);
        await eventually(() => fake.trustArguments);
        abort.complete();

        await expectLater(trusting, throwsA(isA<SshTunnelAbortedException>()));
        expect(fake.knownHosts.existsSync(), isFalse);
      });

      test('rejects a host ssh would read as an option', () async {
        await expectLater(
          client.trustHostKey(const SshTarget('-oProxyCommand=x'), hostKey),
          throwsArgumentError,
        );
        expect(fake.trustArguments, isNull);
      });
    });
  });
}
