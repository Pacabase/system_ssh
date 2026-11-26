@Tags(['integration'])
library;

import 'package:system_ssh/src/shared_connection.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'ssh_fixture.dart';

void main() {
  final fixture = SshFixture();

  group('A key with a passphrase', skip: fixture.skip, () {
    setUpAll(fixture.setUpAll);
    tearDownAll(fixture.tearDownAll);
    setUp(fixture.setUp);
    tearDown(fixture.tearDown);

    Future<SshTunnel> open(SshPromptHandler? onPrompt, {SshTarget? via}) async {
      final tunnel = await openSystemForward(
        via ?? fixture.passphraseTarget,
        forward: localForwardTo(fixture.echoHost, fixture.echoPort),
        onLog: fixture.logged(),
        onPrompt: onPrompt,
        executable: fixture.ssh,
      ).timeout(const Duration(seconds: 60));
      addTearDown(tunnel.close);
      return tunnel;
    }

    test('logs in with the passphrase onPrompt answers', () async {
      final prompts = <SshPrompt>[];

      final tunnel = await open((prompt) async {
        prompts.add(prompt);
        return fixture.keyPassphrase;
      });

      expect(await fixture.echoThrough(tunnel.localPort, 'hello'), 'hello');
      // ssh names the key as the config does, and cuts a long path short.
      final keyPath = (prompts.single as SshPassphrasePrompt).keyPath;
      expect(
        fixture.passphraseKeyPath.replaceAll(r'\', '/'),
        startsWith(keyPath.replaceAll(r'\', '/')),
      );
    });

    test('asks for each hop of a ProxyJump', () async {
      final prompts = <SshPrompt>[];

      final tunnel = await open((prompt) async {
        prompts.add(prompt);
        return fixture.keyPassphrase;
      }, via: fixture.passphraseJumpTarget);

      expect(await fixture.echoThrough(tunnel.localPort, 'hello'), 'hello');
      expect(prompts, hasLength(2));
      expect(prompts, everyElement(isA<SshPassphrasePrompt>()));
    });

    test('logs in with only the key file the target names', () async {
      final prompts = <SshPrompt>[];

      // The runner's own key, which the sshd also trusts, isn't offered.
      final tunnel = await open(
        (prompt) async {
          prompts.add(prompt);
          return fixture.keyPassphrase;
        },
        via: SshTarget(
          '127.0.0.1',
          port: fixture.target.port,
          identityFile: fixture.passphraseKeyPath,
        ),
      );

      expect(await fixture.echoThrough(tunnel.localPort, 'hello'), 'hello');
      expect(prompts.single, isA<SshPassphrasePrompt>());
    });

    test('throws SshLoginCancelledException when onPrompt cancels', () async {
      var asked = 0;

      await expectLater(
        open((_) async {
          asked++;
          return null;
        }),
        throwsA(isA<SshLoginCancelledException>()),
      );
      expect(asked, 1);
    });

    test('throws SshLoginRefusedException for a wrong passphrase', () async {
      var asked = 0;

      await expectLater(
        open((_) async {
          asked++;
          return 'wrong';
        }, via: fixture.passphraseOnceTarget),
        throwsA(isA<SshLoginRefusedException>()),
      );
      expect(asked, 1);
    });

    test('opens a remote forward with the passphrase', () async {
      final tunnel = await openSystemRemoteForward(
        fixture.passphraseTarget,
        localHost: fixture.echoHost,
        localPort: fixture.echoPort,
        onLog: fixture.logged(),
        onPrompt: (_) async => fixture.keyPassphrase,
        executable: fixture.ssh,
      ).timeout(const Duration(seconds: 60));
      addTearDown(tunnel.close);

      expect(tunnel.remotePort, greaterThan(0));
    });

    test('fails without asking when there is no onPrompt', () async {
      await expectLater(open(null), throwsA(isA<SshLoginRefusedException>()));
    });

    test(
      'asks once for tunnels that share a connection',
      () async {
        final pool = ConnectionPool();
        var asked = 0;
        Future<String?> answer(SshPrompt _) async {
          asked++;
          return fixture.keyPassphrase;
        }

        final tunnels = [
          for (var i = 0; i < 2; i++)
            await openSystemForward(
              fixture.passphraseTarget,
              forward: localForwardTo(fixture.echoHost, fixture.echoPort),
              onLog: fixture.logged(),
              onPrompt: answer,
              executable: fixture.ssh,
              pool: pool,
            ),
        ];
        for (final tunnel in tunnels) {
          addTearDown(tunnel.close);
          expect(await fixture.echoThrough(tunnel.localPort, 'hello'), 'hello');
        }
        expect(asked, 1);
      },
      // Windows' OpenSSH can't share a connection.
      testOn: '!windows',
    );
  });

  group('A password', skip: fixture.passwordSkip, () {
    setUpAll(fixture.setUpAll);
    tearDownAll(fixture.tearDownAll);
    setUp(fixture.setUp);
    tearDown(fixture.tearDown);

    Future<SshTunnel> open(SshPromptHandler onPrompt, {SshTarget? via}) async {
      final tunnel = await openSystemForward(
        via ?? fixture.passwordTarget,
        forward: localForwardTo(fixture.echoHost, fixture.echoPort),
        onLog: fixture.logged(),
        onPrompt: onPrompt,
        executable: fixture.ssh,
      ).timeout(const Duration(seconds: 60));
      addTearDown(tunnel.close);
      return tunnel;
    }

    test('logs in with the password onPrompt answers', () async {
      final prompts = <SshPrompt>[];

      final tunnel = await open((prompt) async {
        prompts.add(prompt);
        return fixture.password;
      });

      expect(await fixture.echoThrough(tunnel.localPort, 'hello'), 'hello');
      expect(prompts.single, isA<SshPasswordPrompt>());
      // Before OpenSSH 8.5, ssh doesn't say which login a prompt is for.
      expect(prompts.single.isVerified, fixture.sshIsAtLeast(8, 5));
    });

    test('throws SshLoginRefusedException for a wrong password', () async {
      await expectLater(
        open((_) async => 'wrong-password'),
        throwsA(isA<SshLoginRefusedException>()),
      );
    });

    test('throws SshLoginCancelledException when onPrompt cancels', () async {
      await expectLater(
        open((_) async => null),
        throwsA(isA<SshLoginCancelledException>()),
      );
    });

    test(
      "answers the server's own question, as for a 2FA code",
      () async {
        final prompts = <SshPrompt>[];

        final tunnel = await open((prompt) async {
          prompts.add(prompt);
          return fixture.password;
        }, via: fixture.keyboardInteractiveTarget);

        expect(await fixture.echoThrough(tunnel.localPort, 'hello'), 'hello');
        expect(prompts.single, isA<SshCodePrompt>());
        expect(prompts.single.text, contains('Password'));
        expect(prompts.single.isVerified, fixture.sshIsAtLeast(8, 5));
      },
      // Windows' sshd has no PAM to ask through keyboard-interactive.
      testOn: '!windows',
    );
  });
}
