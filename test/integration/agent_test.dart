// Windows' ssh-agent is a service, not a socket a test can start.
@TestOn('!windows')
@Tags(['integration'])
library;

import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'ssh_fixture.dart';

void main() {
  final fixture = SshFixture();

  group(
    'An ssh agent',
    skip: fixture.skip,
    () {
      setUpAll(() async {
        await fixture.setUpAll();
        await fixture.startAgent();
      });
      tearDownAll(() async {
        await fixture.stopAgent();
        await fixture.tearDownAll();
      });
      setUp(fixture.setUp);
      tearDown(fixture.tearDown);

      Future<SshTunnel> open(
        SshTarget via, {
        Map<String, String> environment = const {},
      }) async {
        final log = <String>[];
        addTearDown(() => printOnFailure('ssh log:\n${log.join('\n')}'));
        final tunnel = await openSystemTunnel(
          via,
          remoteHost: fixture.echoHost,
          remotePort: fixture.echoPort,
          onLog: log.add,
          executable: fixture.ssh,
          environment: environment,
        );
        addTearDown(tunnel.close);
        return tunnel;
      }

      test('logs in through SSH_AUTH_SOCK with no key file', () async {
        final tunnel = await open(
          fixture.agentOnlyTarget,
          environment: {'SSH_AUTH_SOCK': fixture.agentSocket},
        );

        expect(await fixture.echoThrough(tunnel.localPort, 'hello'), 'hello');
      });

      test('logs in through the agent IdentityAgent names', () async {
        final tunnel = await open(fixture.identityAgentTarget);

        expect(await fixture.echoThrough(tunnel.localPort, 'hello'), 'hello');
      });

      test('fails at once when the agent is not there', () async {
        await expectLater(
          open(fixture.deadAgentTarget).timeout(const Duration(seconds: 20)),
          throwsA(
            isA<SshTunnelException>().having(
              (exception) => exception.isPermanent,
              'isPermanent',
              isTrue,
            ),
          ),
        );
      });
    },
  );
}
