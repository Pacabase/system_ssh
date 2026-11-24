import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

final class _FakeTunnel implements SshTunnel {
  _FakeTunnel(this.localPort);

  @override
  final int localPort;

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> close() async {}
}

final class _FakeRemoteTunnel implements SshRemoteTunnel {
  _FakeRemoteTunnel(this.remotePort);

  @override
  final int remotePort;

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> close() async {}
}

final class _FakeSshClient implements SshClient {
  @override
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    SshPromptHandler? onPrompt,
    Future<void>? abortTrigger,
  }) async =>
      _FakeTunnel(localPort ?? 50000);

  @override
  Future<SshTunnel> openSocketTunnel(
    SshTarget server, {
    required String remoteSocket,
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    SshPromptHandler? onPrompt,
    Future<void>? abortTrigger,
  }) async =>
      _FakeTunnel(localPort ?? 50002);

  @override
  Future<SshRemoteTunnel> openRemoteTunnel(
    SshTarget server, {
    String localHost = 'localhost',
    required int localPort,
    int? remotePort,
    void Function(SshLog log)? onLog,
    SshPromptHandler? onPrompt,
    Future<void>? abortTrigger,
  }) async =>
      _FakeRemoteTunnel(remotePort ?? 41234);

  @override
  Future<SshTunnel> openSocksProxy(
    SshTarget server, {
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    SshPromptHandler? onPrompt,
    Future<void>? abortTrigger,
  }) async =>
      _FakeTunnel(localPort ?? 50001);

  @override
  Future<List<String>> configuredHosts() async => const ['ssh.example.com'];

  final trusted = <SshHostKey>[];

  @override
  Future<void> trustHostKey(
    SshTarget server,
    SshHostKey hostKey, {
    Future<void>? abortTrigger,
  }) async =>
      trusted.add(hostKey);
}

const _hostKey = SshHostKey(
  host: '[ssh.example.com]:2222',
  type: 'ED25519',
  fingerprint: 'SHA256:fakeHostKeyFingerprintFakeHostKeyFingerpri',
);

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
          SshLoginStarted(:final line) => 'login: $line',
          SshMessage(:final line) => 'message: $line',
          SshForwardUnreachable(:final line, :final reason) => '$reason: $line',
          SshForwardProhibited(:final line) => 'forbidden: $line',
        };

    expect(
      [
        const SshProgress('debug1: Server host key: ssh-ed25519 SHA256:x'),
        const SshLoginStarted('debug1: Connecting to ssh.example.com port 22.'),
        const SshMessage('Warning: Permanently added ssh.example.com.'),
        const SshForwardUnreachable(
          'channel 2: open failed: connect failed: Connection refused',
          reason: 'Connection refused',
        ),
        const SshForwardProhibited(
          'channel 3: open failed: administratively prohibited: open failed',
        ),
      ].map(describe),
      [
        startsWith('progress: '),
        startsWith('login: '),
        startsWith('message: '),
        startsWith('Connection refused: '),
        startsWith('forbidden: '),
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

  test('opens a remote tunnel, on a fixed server port or a picked one',
      () async {
    final SshClient fake = _FakeSshClient();
    final SshRemoteTunnel picked = await fake.openRemoteTunnel(
      const SshTarget('ssh.example.com'),
      localPort: 3000,
    );
    final fixed = await fake.openRemoteTunnel(
      const SshTarget('ssh.example.com'),
      localHost: '127.0.0.1',
      localPort: 3000,
      remotePort: 8080,
    );

    expect((picked.remotePort, fixed.remotePort), (41234, 8080));
    await fixed.close();
    await fixed.done;
  });

  test('holds every kind of tunnel as an SshForward', () async {
    final SshClient fake = _FakeSshClient();
    final forwards = <SshForward>[
      await fake.openTunnel(
        const SshTarget('ssh.example.com'),
        remoteHost: 'db.example.com',
        remotePort: 5432,
      ),
      await fake.openSocketTunnel(
        const SshTarget('ssh.example.com'),
        remoteSocket: '/var/run/docker.sock',
      ),
      await fake.openSocksProxy(const SshTarget('ssh.example.com')),
      await fake.openRemoteTunnel(
        const SshTarget('ssh.example.com'),
        localPort: 3000,
      ),
    ];

    await Future.wait(forwards.map((forward) => forward.close()));
    await Future.wait(forwards.map((forward) => forward.done));
  });

  test('opens a tunnel to a Unix socket on the server', () async {
    final SshClient fake = _FakeSshClient();
    final tunnel = await fake.openSocketTunnel(
      const SshTarget('ssh.example.com'),
      remoteSocket: '/var/run/docker.sock',
      localPort: 2375,
    );

    expect(tunnel.localPort, 2375);
    expect(
      socketTunnelCommand(
        const SshTarget('ssh.example.com'),
        remoteSocket: '/var/run/docker.sock',
        localPort: 2375,
      ),
      contains('-L 127.0.0.1:2375:/var/run/docker.sock'),
    );
  });

  test('rejects a relative socket path', () async {
    await expectLater(
      const SystemSshClient().openSocketTunnel(
        const SshTarget('ssh.example.com'),
        remoteSocket: 'docker.sock',
      ),
      throwsArgumentError,
    );
  });

  test('shows the terminal command for a remote tunnel', () {
    expect(
      remoteTunnelCommand(
        const SshTarget('ssh.example.com'),
        localPort: 3000,
        remotePort: 8080,
      ),
      contains('-R 127.0.0.1:8080:localhost:3000'),
    );
  });

  test('rejects a remote tunnel port outside 1 to 65535', () async {
    await expectLater(
      const SystemSshClient().openRemoteTunnel(
        const SshTarget('ssh.example.com'),
        localPort: 3000,
        remotePort: 0,
      ),
      throwsArgumentError,
    );
  });

  test('lets a switch name every exception', () {
    String reason(SshException exception) => switch (exception) {
          SshNotFoundException() => 'no ssh',
          SshConfigException() => 'config',
          SshPortInUseException(:final port) => 'port $port in use',
          SshDuplicateForwardException(:final forward) => 'already $forward',
          SshLoginRefusedException() => 'login refused',
          SshHostKeyRefusedException() => 'host key refused',
          SshUnknownHostKeyException(:final hostKey) =>
            'unknown ${hostKey.host}',
          SshHostKeyChangedException() => 'host key changed',
          SshHostNotFoundException() => 'host not found',
          SshUnreachableException() => 'unreachable',
          SshDroppedException() => 'dropped',
          SshAddressUnavailableException(:final address) => 'no $address',
          SshRemotePortRefusedException(:final port) => 'server port $port',
          SshFailedException() => 'failed',
          SshTunnelAbortedException() => 'aborted',
          SshLoginCancelledException() => 'cancelled',
        };

    expect(reason(const SshPortInUseException(5432)), 'port 5432 in use');
    expect(
      reason(const SshRemotePortRefusedException('refused', port: 8080)),
      'server port 8080',
    );
  });

  test('lets a switch name every prompt', () {
    String ask(SshPrompt prompt) => switch (prompt) {
          SshPassphrasePrompt(:final keyPath) => 'passphrase for $keyPath',
          SshPasswordPrompt() => 'password',
          SshCodePrompt(:final text) => 'code: $text',
        };

    expect(
      ask(const SshPassphrasePrompt('Enter passphrase', keyPath: '/k')),
      'passphrase for /k',
    );
    expect(ask(const SshPasswordPrompt("a@b's password: ")), 'password');
    expect(ask(const SshCodePrompt('Code: ')), 'code: Code: ');
  });

  test('acts out an unknown host key and trusts it', () async {
    final fake = _FakeSshClient();
    final unknown = SshUnknownHostKeyException(
      _hostKey,
      log: const ['Host key verification failed.'],
      exitCode: 255,
    );
    final changed = SshHostKeyChangedException(_hostKey);

    await fake.trustHostKey(
        const SshTarget('ssh.example.com'), unknown.hostKey);

    expect(
      [unknown, changed],
      everyElement(
        isA<SshException>().having(
          (exception) => exception is SshPermanentException,
          'is permanent',
          isTrue,
        ),
      ),
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
