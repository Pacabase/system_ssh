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

  test('reads back the target it was given', () {
    const target = SshTarget('ssh.example.com', port: 2222, user: 'alice');

    expect((target.host, target.port, target.user),
        ('ssh.example.com', 2222, 'alice'));
  });

  test('waits on a tunnel and closes it', () async {
    final SshTunnel tunnel = await _FakeSshClient().openTunnel(
      const SshTarget('ssh.example.com'),
      remoteHost: 'db.example.com',
      remotePort: 5432,
    );

    await tunnel.close();
    await tunnel.done;
  });

  test('runs a chosen ssh executable', () {
    const client = SystemSshClient(executable: '/usr/local/bin/ssh');

    expect(client.executable, '/usr/local/bin/ssh');
  });

  test('switches over every kind of log line', () {
    String describe(SshLog log) => switch (log) {
          SshProgress(:final line) => 'progress: $line',
          SshMessage(:final line) => 'message: $line',
          SshForwardFailed(:final line, :final reason) => '$reason: $line',
        };

    expect(
      [
        const SshProgress('debug1: Connecting to ssh.example.com port 22.'),
        const SshMessage('Warning: Permanently added ssh.example.com.'),
        const SshForwardFailed(
          'channel 2: open failed: connect failed: Connection refused',
          reason: 'Connection refused',
        ),
      ].map(describe),
      [
        startsWith('progress: '),
        startsWith('message: '),
        startsWith('Connection refused: '),
      ],
    );
  });

  test('shows the terminal command for a tunnel and a SOCKS proxy', () {
    const server = SshTarget('ssh.example.com');

    expect(
      tunnelCommand(
        server,
        remoteHost: 'db.example.com',
        remotePort: 5432,
        localPort: 15432,
      ),
      contains('-L 127.0.0.1:15432:db.example.com:5432'),
    );
    expect(
      socksProxyCommand(server, localPort: 1080),
      contains('-D 127.0.0.1:1080'),
    );
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
    ];

    expect(
      exceptions.map((exception) => exception.message),
      everyElement(isNotEmpty),
    );
  });

  test('says whether retrying an exception can work', () {
    const tunnelException = SshTunnelException(
      'Host key verification failed.',
      log: ['debug1: Connecting to ssh.example.com port 22.'],
      exitCode: 255,
      isPermanent: true,
    );
    const portInUse = SshPortInUseException(5432);

    expect(const SshException('boom').isPermanent, isFalse);
    expect(SshNotFoundException().isPermanent, isTrue);
    expect(const SshTunnelAbortedException().isPermanent, isFalse);
    expect(tunnelException.log,
        ['debug1: Connecting to ssh.example.com port 22.']);
    expect(
        (tunnelException.exitCode, tunnelException.isPermanent), (255, true));
    expect((portInUse.port, portInUse.isPermanent), (5432, true));
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
