import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

class _FakeTunnel implements SshTunnel {
  _FakeTunnel(this.localPort);

  @override
  final int localPort;

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
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      _FakeTunnel(localPort ?? 50000);

  @override
  Future<SshTunnel> openSocksProxy(
    SshTarget server, {
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      _FakeTunnel(localPort ?? 50001);

  @override
  Future<List<String>> configuredHosts() async => const ['ssh.example.com'];
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
    expect(await fake.configuredHosts(), ['ssh.example.com']);
  });

  test('takes the login shell and extra variables for ssh', () {
    const client = SystemSshClient(
      loginShell: true,
      environment: {'AWS_PROFILE': 'staging'},
    );

    expect(client.loginShell, isTrue);
    expect(client.environment, {'AWS_PROFILE': 'staging'});
  });

  test('takes a fixed local port', () async {
    final tunnel = await _FakeSshClient().openTunnel(
      const SshTarget('ssh.example.com'),
      remoteHost: 'db.example.com',
      remotePort: 5432,
      localPort: 15432,
    );

    expect(tunnel.localPort, 15432);
  });

  test('opens a SOCKS proxy, on a fixed local port or a free one', () async {
    final SshClient fake = _FakeSshClient();
    final proxy = await fake.openSocksProxy(const SshTarget('ssh.example.com'));
    final fixed = await fake.openSocksProxy(
      const SshTarget('ssh.example.com'),
      localPort: 1080,
    );

    expect(proxy.localPort, 50001);
    expect(fixed.localPort, 1080);
  });

  test('exports every exception as an SshException with a message', () {
    final exceptions = <SshException>[
      const SshException('boom'),
      SshNotFoundException(),
      const SshTunnelAbortedException(),
      const SshTunnelException('boom', exitCode: 255),
      const SshPortInUseException(5432),
      const SshConfigException('boom'),
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

  test('rejects a local port outside 1 to 65535', () async {
    await expectLater(
      const SystemSshClient().openTunnel(
        const SshTarget('ssh.example.com'),
        remoteHost: 'db.example.com',
        remotePort: 5432,
        localPort: 0,
      ),
      throwsArgumentError,
    );
  });

  test('rejects a SOCKS proxy server host that ssh would read as an option',
      () async {
    await expectLater(
      const SystemSshClient().openSocksProxy(
        const SshTarget('-oProxyCommand=false'),
      ),
      throwsArgumentError,
    );
  });

  test('rejects a SOCKS proxy port outside 1 to 65535', () async {
    await expectLater(
      const SystemSshClient().openSocksProxy(
        const SshTarget('ssh.example.com'),
        localPort: 65536,
      ),
      throwsArgumentError,
    );
  });
}
