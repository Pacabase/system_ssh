import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

class _FakeTunnel implements SshTunnel {
  @override
  int get localPort => 50000;

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> close() async {}
}

class _FakeSshClient implements SshClient {
  @override
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    void Function(String line)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      _FakeTunnel();
}

void main() {
  test('exports the client, its target and tunnel', () async {
    const SshClient client = SystemSshClient();
    final SshClient fake = _FakeSshClient();
    final tunnel = await fake.openTunnel(
      const SshTarget('ssh.example.com', port: 22, user: 'alice'),
      remoteHost: 'db.example.com',
      remotePort: 5432,
    );

    expect(client, isA<SystemSshClient>());
    expect(tunnel.localPort, 50000);
  });

  test('exports every exception as an SshException with a message', () {
    final exceptions = <SshException>[
      const SshException('boom'),
      SshNotFoundException(),
      const SshTunnelAbortedException(),
      const SshTunnelException('boom', exitCode: 255),
    ];

    expect(
      exceptions.map((exception) => exception.message),
      everyElement(isNotEmpty),
    );
  });

  test('rejects a server host that ssh would read as an option', () async {
    await expectLater(
      const SystemSshClient().openTunnel(
        const SshTarget('-oProxyCommand=false'),
        remoteHost: 'db.example.com',
        remotePort: 5432,
      ),
      throwsArgumentError,
    );
  });
}
