@Tags(['integration'])
library;

import 'package:system_ssh/src/shared_connection.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'ssh_fixture.dart';

void main() {
  final fixture = SshFixture();

  group(
    'A key with a passphrase',
    skip: fixture.skip,
    () {
      setUpAll(fixture.setUpAll);
      tearDownAll(fixture.tearDownAll);
      setUp(fixture.setUp);
      tearDown(fixture.tearDown);

      Future<SshTunnel> open(SshPromptHandler? onPrompt) async {
        final tunnel = await openSystemForward(
          fixture.passphraseTarget,
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

      test('throws SshLoginCancelledException when onPrompt cancels', () async {
        await expectLater(
          open((_) async => null),
          throwsA(isA<SshLoginCancelledException>()),
        );
      });

      test('throws SshLoginRefusedException for a wrong passphrase', () async {
        var asked = 0;

        await expectLater(
          open((_) async {
            asked++;
            return 'wrong';
          }),
          throwsA(isA<SshLoginRefusedException>()),
        );
        expect(asked, greaterThan(0));
      });

      test('fails without asking when there is no onPrompt', () async {
        await expectLater(
          open(null),
          throwsA(isA<SshLoginRefusedException>()),
        );
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
            expect(
              await fixture.echoThrough(tunnel.localPort, 'hello'),
              'hello',
            );
          }
          expect(asked, 1);
        },
        // Windows' OpenSSH can't share a connection.
        testOn: '!windows',
      );
    },
  );
}
