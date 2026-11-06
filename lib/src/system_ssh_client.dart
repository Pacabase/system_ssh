import 'dart:async';
import 'dart:io';

import 'config_hosts.dart';
import 'exceptions.dart';
import 'logger.dart';
import 'login_shell.dart';
import 'ports.dart';
import 'processes.dart';
import 'ssh_client.dart';
import 'ssh_command.dart';
import 'ssh_config.dart';
import 'ssh_log.dart';
import 'ssh_target.dart';
import 'system_ssh_tunnel.dart';

/// Tunnels through the system's OpenSSH client, with `~/.ssh/config` and its
/// agent applying as they do in a terminal.
final class SystemSshClient implements SshClient {
  const SystemSshClient({
    this.executable = 'ssh',
    this.loginShell = false,
    this.environment = const {},
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

  @override
  Future<List<String>> configuredHosts() {
    final home = environment['HOME'] ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final ssh = '${home.replaceAll(r'\', '/')}/.ssh';

    return readConfigHosts('$ssh/config', sshDirectory: ssh);
  }

  @override
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      openSystemForward(
        server,
        forward: localForwardTo(remoteHost, remotePort),
        localPort: localPort,
        onLog: onLog,
        abortTrigger: abortTrigger,
        executable: executable,
        environment: await _sshEnvironment(),
      );

  @override
  Future<SshTunnel> openSocksProxy(
    SshTarget server, {
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      openSystemForward(
        server,
        forward: dynamicForward,
        localPort: localPort,
        onLog: onLog,
        abortTrigger: abortTrigger,
        executable: executable,
        environment: await _sshEnvironment(),
      );

  Future<Map<String, String>> _sshEnvironment() async => {
        if (loginShell) ...await cachedLoginShellEnvironment(),
        ...environment,
      };
}

// ssh before 9.6 hands %h and %r to a ProxyCommand's shell unescaped.
final _unsafeInHost = RegExp(r'''[\s'"`$;&|<>(){}\\/]|[\x00-\x1f]''');
final _unsafeInUser = RegExp(r'''[\s'"`$;&|<>(){}/]|[\x00-\x1f]''');

/// The `-L` forward to [remoteHost]:[remotePort], for [openSystemForward].
List<String> Function(int localPort) localForwardTo(
  String remoteHost,
  int remotePort,
) {
  if (remoteHost.contains(_unsafeInHost)) {
    throw ArgumentError.value(remoteHost, 'remoteHost', 'is not a valid host');
  }

  return (port) => localForward(
        port,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );
}

/// [SystemSshClient.openTunnel] and [SystemSshClient.openSocksProxy], with
/// the parts tests replace.
Future<SshTunnel> openSystemForward(
  SshTarget server, {
  required List<String> Function(int localPort) forward,
  int? localPort,
  void Function(SshLog log)? onLog,
  Future<void>? abortTrigger,
  String executable = 'ssh',
  Map<String, String> environment = const {},
  Future<int> Function() freePort = pickFreePort,
  Future<bool> Function(int port) portIsFree = isPortFree,
  Duration configTimeout = const Duration(seconds: 5),
}) async {
  if (server.host.startsWith('-') || server.host.contains(_unsafeInHost)) {
    throw ArgumentError.value(server.host, 'server', 'is not a valid host');
  }
  if (server.user case final user?
      when user.startsWith('-') || user.contains(_unsafeInUser)) {
    throw ArgumentError.value(user, 'server', 'is not a valid user');
  }
  if (localPort case final port? when port < 1 || port > 65535) {
    throw RangeError.range(port, 1, 65535, 'localPort');
  }

  var isAborted = false;
  unawaited(abortTrigger?.then((_) => isAborted = true, onError: (_) {}));

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

  Future<SshTunnel> start(int port) async {
    final command = sshCommand(
      server,
      forward: forward(port),
      config: config,
      executable: ssh,
    );
    logger.info(command.join(' '));

    try {
      return await SystemSshTunnel.attach(
        await startWatched(command, environment: environment),
        localPort: port,
        onLog: onLog,
        abortTrigger: abortTrigger,
      );
    } on SshTunnelException catch (exception) {
      // sh's code for a missing command; Windows fails to start instead.
      if (exception.exitCode == 127) throw SshNotFoundException();
      rethrow;
    }
  }

  if (localPort != null) {
    if (isAborted) throw const SshTunnelAbortedException();
    if (!await portIsFree(localPort)) throw SshPortInUseException(localPort);
    if (isAborted) throw const SshTunnelAbortedException();

    try {
      return await start(localPort);
    } on SshTunnelException {
      if (await portIsFree(localPort)) rethrow;
      throw SshPortInUseException(localPort);
    }
  }

  for (var attempt = 1;; attempt++) {
    if (isAborted) throw const SshTunnelAbortedException();

    final port = await freePort();
    if (isAborted) throw const SshTunnelAbortedException();

    try {
      return await start(port);
    } on SshTunnelException {
      // Another process can take the port before ssh binds it.
      if (attempt == 3 || await portIsFree(port)) rethrow;
    }
  }
}
