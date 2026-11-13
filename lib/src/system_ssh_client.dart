import 'dart:async';
import 'dart:io';

import 'config_hosts.dart';
import 'exceptions.dart';
import 'host_keys.dart';
import 'logger.dart';
import 'login_shell.dart';
import 'ports.dart';
import 'processes.dart';
import 'shared_connection.dart';
import 'ssh_client.dart';
import 'ssh_command.dart';
import 'ssh_config.dart';
import 'ssh_host_key.dart';
import 'ssh_log.dart';
import 'ssh_output.dart';
import 'ssh_target.dart';
import 'system_ssh_tunnel.dart';

/// Tunnels through the system's OpenSSH client, with `~/.ssh/config` and its
/// agent applying as they do in a terminal.
final class SystemSshClient implements SshClient {
  /// A client that runs `ssh` from the `PATH` with the app's own environment,
  /// one ssh per tunnel, unless [executable], [loginShell], [environment] or
  /// [shareConnections] say otherwise.
  const SystemSshClient({
    this.executable = 'ssh',
    this.loginShell = false,
    this.environment = const {},
    this.shareConnections = false,
  });

  /// The OpenSSH client to run: a path, or a name looked up on the `PATH`.
  final String executable;

  /// Whether ssh also gets the `PATH`, `HOME`, `DISPLAY` and `SSH_` variables
  /// the user's login shell sets, which a GUI app doesn't inherit. The shell
  /// runs once per process, on the first tunnel.
  final bool loginShell;

  /// Variables ssh gets on top of the rest, such as an `AWS_PROFILE` for a
  /// `ProxyCommand`.
  final Map<String, String> environment;

  /// Whether tunnels to the same server share one ssh connection, so the
  /// server sees one login, and a hardware key that asks for a touch, or an
  /// agent that confirms each use, asks once rather than once per tunnel.
  ///
  /// The connection is this process's own, never one the user's
  /// `ControlMaster` set up, and it stops once its last tunnel closes, or
  /// with the app. When it drops, every tunnel on it fails [SshTunnel.done]
  /// together. Windows' OpenSSH can't share a connection, so there each
  /// tunnel keeps its own ssh.
  final bool shareConnections;

  ConnectionPool? get _pool =>
      shareConnections && !Platform.isWindows ? connectionPool : null;

  @override
  Future<List<String>> configuredHosts() {
    final ssh = '${homeDirectory(environment)}/.ssh';

    return readConfigHosts('$ssh/config', sshDirectory: ssh);
  }

  @override
  Future<void> trustHostKey(
    SshTarget server,
    SshHostKey hostKey, {
    Future<void>? abortTrigger,
  }) async {
    checkServer(server);
    var isAborted = false;
    unawaited(abortTrigger?.then((_) => isAborted = true, onError: (_) {}));

    final environment = await _sshEnvironment();
    final ssh = resolveExecutable(executable, environment: environment);
    final config = await resolveConfig(
      server,
      executable: ssh,
      environment: environment,
      abortTrigger: abortTrigger,
    );
    if (isAborted) throw const SshTunnelAbortedException();

    await trustSystemHostKey(
      server,
      hostKey,
      executable: ssh,
      config: config,
      environment: environment,
      abortTrigger: abortTrigger,
    );
  }

  @override
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      openSystemForward(
        server,
        forward: localForwardTo(
          remoteHost,
          remotePort,
          bindAddress: bindAddress,
        ),
        bindAddress: bindAddress,
        localPort: localPort,
        onLog: onLog,
        abortTrigger: abortTrigger,
        executable: executable,
        environment: await _sshEnvironment(),
        pool: _pool,
      );

  @override
  Future<SshTunnel> openSocketTunnel(
    SshTarget server, {
    required String remoteSocket,
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      openSystemForward(
        server,
        forward: localForwardToSocketAt(remoteSocket, bindAddress: bindAddress),
        bindAddress: bindAddress,
        localPort: localPort,
        onLog: onLog,
        abortTrigger: abortTrigger,
        executable: executable,
        environment: await _sshEnvironment(),
        pool: _pool,
      );

  @override
  Future<SshRemoteTunnel> openRemoteTunnel(
    SshTarget server, {
    String localHost = 'localhost',
    required int localPort,
    int? remotePort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      openSystemRemoteForward(
        server,
        localHost: localHost,
        localPort: localPort,
        remotePort: remotePort,
        onLog: onLog,
        abortTrigger: abortTrigger,
        executable: executable,
        environment: await _sshEnvironment(),
        pool: _pool,
      );

  @override
  Future<SshTunnel> openSocksProxy(
    SshTarget server, {
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      openSystemForward(
        server,
        forward: dynamicForwardOn(bindAddress),
        bindAddress: bindAddress,
        localPort: localPort,
        onLog: onLog,
        abortTrigger: abortTrigger,
        executable: executable,
        environment: await _sshEnvironment(),
        pool: _pool,
      );

  Future<Map<String, String>> _sshEnvironment() async => {
        if (loginShell) ...await cachedLoginShellEnvironment(),
        ...environment,
      };
}

// ssh before 9.6 hands %h and %r to a ProxyCommand's shell unescaped.
final _unsafeInUser = RegExp(r'''[\s'"`$;&|<>(){}/]|[\x00-\x1f]''');

List<String> Function(int localPort) localForwardTo(
  String remoteHost,
  int remotePort, {
  String bindAddress = '127.0.0.1',
}) {
  checkHost(remoteHost, 'remoteHost');
  checkBindAddress(bindAddress);

  return (port) => localForward(
        port,
        bindAddress: bindAddress,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );
}

List<String> Function(int localPort) localForwardToSocketAt(
  String remoteSocket, {
  String bindAddress = '127.0.0.1',
}) {
  checkSocketPath(remoteSocket, 'remoteSocket');
  checkBindAddress(bindAddress);
  return (port) => localForwardToSocket(
        port,
        bindAddress: bindAddress,
        remoteSocket: remoteSocket,
      );
}

List<String> Function(int localPort) dynamicForwardOn(String bindAddress) {
  checkBindAddress(bindAddress);
  return (port) => dynamicForward(port, bindAddress: bindAddress);
}

/// [SystemSshClient.openTunnel] and [SystemSshClient.openSocksProxy], with
/// the parts tests replace.
Future<SshTunnel> openSystemForward(
  SshTarget server, {
  required List<String> Function(int localPort) forward,
  String bindAddress = '127.0.0.1',
  int? localPort,
  void Function(SshLog log)? onLog,
  Future<void>? abortTrigger,
  String executable = 'ssh',
  Map<String, String> environment = const {},
  Future<int> Function()? freePort,
  Future<bool> Function(int port)? portIsFree,
  Duration configTimeout = const Duration(seconds: 5),
  ConnectionPool? pool,
}) async {
  checkServer(server);
  if (localPort != null) checkLocalPort(localPort);
  final isFree = portIsFree ?? (port) => isPortFree(port, address: bindAddress);
  final pickPort = freePort ?? () => pickFreePort(address: bindAddress);

  var isAborted = false;
  unawaited(abortTrigger?.then((_) => isAborted = true, onError: (_) {}));

  final (ssh, config) = await _resolve(
    server,
    executable: executable,
    environment: environment,
    configTimeout: configTimeout,
    abortTrigger: abortTrigger,
  );
  if (isAborted) throw const SshTunnelAbortedException();
  // A taken port, or an address this computer lacks, needs no login to say
  // so. Port 0 checks the address alone.
  if (pool != null) {
    if (localPort == null) {
      await isPortFree(0, address: bindAddress);
    } else if (!await isFree(localPort)) {
      throw SshPortInUseException(localPort, address: bindAddress);
    }
  }
  // Held while it opens, so a retry on a taken port reuses the login.
  final shared = await checkingHostKeys(
    config,
    () async => pool?.connect(
      server,
      executable: ssh,
      environment: environment,
      config: config,
      onLog: onLog,
      abortTrigger: abortTrigger,
    ),
  );

  Future<SshTunnel> start(int port) async {
    if (shared != null) {
      final (handle, _) = await shared.forward(
        forward(port),
        localPort: port,
        onLog: onLog,
        abortTrigger: abortTrigger,
      );
      if (isAborted) {
        await handle.close();
        throw const SshTunnelAbortedException();
      }
      return SystemSshTunnel(port, handle);
    }

    final command = sshCommand(
      server,
      forward: forward(port),
      config: config,
      executable: ssh,
    );
    logger.info(command.join(' '));

    return notFoundOn127(
      () async => SystemSshTunnel.attach(
        await startWatched(command, environment: environment),
        localPort: port,
        bindAddress: bindAddress,
        onLog: onLog,
        abortTrigger: abortTrigger,
      ),
    );
  }

  Future<SshTunnel> open() async {
    if (localPort != null) {
      if (isAborted) throw const SshTunnelAbortedException();
      if (!await isFree(localPort)) {
        throw SshPortInUseException(localPort, address: bindAddress);
      }
      if (isAborted) throw const SshTunnelAbortedException();

      try {
        return await start(localPort);
      } on SshTunnelException catch (exception) {
        // A host key or a login that failed isn't about the port.
        if (exception.isPermanent || await isFree(localPort)) rethrow;
        throw SshPortInUseException(localPort, address: bindAddress);
      }
    }

    for (var attempt = 1;; attempt++) {
      if (isAborted) throw const SshTunnelAbortedException();

      final port = await pickPort();
      if (isAborted) throw const SshTunnelAbortedException();

      try {
        return await start(port);
      } on SshTunnelException catch (exception) {
        // Another process can take the port before ssh binds it.
        if (exception.isPermanent || attempt == 3 || await isFree(port)) {
          rethrow;
        }
      }
    }
  }

  try {
    return await checkingHostKeys(config, open);
  } finally {
    shared?.release();
  }
}

/// [SystemSshClient.openRemoteTunnel], with the parts tests replace.
Future<SshRemoteTunnel> openSystemRemoteForward(
  SshTarget server, {
  required String localHost,
  required int localPort,
  int? remotePort,
  void Function(SshLog log)? onLog,
  Future<void>? abortTrigger,
  String executable = 'ssh',
  Map<String, String> environment = const {},
  Duration configTimeout = const Duration(seconds: 5),
  ConnectionPool? pool,
}) async {
  checkServer(server);
  checkHost(localHost, 'localHost');
  checkLocalPort(localPort);
  if (remotePort != null) checkPort(remotePort, 'remotePort');

  var isAborted = false;
  unawaited(abortTrigger?.then((_) => isAborted = true, onError: (_) {}));

  final (ssh, config) = await _resolve(
    server,
    executable: executable,
    environment: environment,
    configTimeout: configTimeout,
    abortTrigger: abortTrigger,
  );
  if (isAborted) throw const SshTunnelAbortedException();

  final forward = remoteForward(
    remotePort ?? 0,
    localHost: localHost,
    localPort: localPort,
  );

  if (pool != null) {
    final shared = await checkingHostKeys(
      config,
      () => pool.connect(
        server,
        executable: ssh,
        environment: environment,
        config: config,
        onLog: onLog,
        abortTrigger: abortTrigger,
      ),
    );
    try {
      if (isAborted) throw const SshTunnelAbortedException();
      final (handle, printed) = await shared.forward(
        forward,
        onLog: onLog,
        abortTrigger: abortTrigger,
      );
      final port = remotePort ?? int.tryParse(printed);
      if (isAborted || port == null) {
        await handle.close();
        if (isAborted) throw const SshTunnelAbortedException();
        throw const SshException(
          "ssh didn't say which port the server picked",
        );
      }
      return SystemSshRemoteTunnel(port, handle);
    } finally {
      shared.release();
    }
  }

  final command = sshCommand(
    server,
    forward: forward,
    config: config,
    executable: ssh,
  );
  logger.info(command.join(' '));

  return checkingHostKeys(
    config,
    () => notFoundOn127(
      () async => SystemSshRemoteTunnel.attach(
        await startWatched(command, environment: environment),
        readiness: RemoteForwardReadiness(
          remotePort ?? 0,
          localHost: localHost,
          localPort: localPort,
        ),
        onLog: onLog,
        abortTrigger: abortTrigger,
      ),
    ),
  );
}

void checkServer(SshTarget server) {
  if (server.host.startsWith('-')) {
    throw ArgumentError.value(server.host, 'server', 'is not a valid host');
  }
  checkHost(server.host, 'server');
  if (server.user case final user?
      when user.startsWith('-') || user.contains(_unsafeInUser)) {
    throw ArgumentError.value(user, 'server', 'is not a valid user');
  }
}

/// The ssh to run, and what `ssh -G` says the config makes of [server].
Future<(String, Map<String, String>)> _resolve(
  SshTarget server, {
  required String executable,
  required Map<String, String> environment,
  required Duration configTimeout,
  Future<void>? abortTrigger,
}) async {
  final ssh = resolveExecutable(executable, environment: environment);
  final config = await resolveConfig(
    server,
    executable: ssh,
    environment: environment,
    timeout: configTimeout,
    abortTrigger: abortTrigger,
  );
  if (config['clearallforwardings'] == 'yes') {
    throw SshConfigException(
      '~/.ssh/config sets ClearAllForwardings for ${server.host}, '
      'which drops the tunnel',
    );
  }
  return (ssh, config);
}
