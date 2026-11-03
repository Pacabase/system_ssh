import 'dart:async';

import 'exceptions.dart';
import 'logger.dart';
import 'ports.dart';
import 'processes.dart';
import 'ssh_client.dart';
import 'ssh_command.dart';
import 'ssh_config.dart';
import 'ssh_target.dart';
import 'system_ssh_tunnel.dart';

/// Tunnels through the system's OpenSSH client, with `~/.ssh/config` and its
/// agent applying as they do in a terminal.
final class SystemSshClient implements SshClient {
  const SystemSshClient({this.executable = 'ssh'});

  /// The OpenSSH client to run: a path, or a name looked up on the `PATH`.
  final String executable;

  @override
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    void Function(String line)? onLog,
    Future<void>? abortTrigger,
  }) =>
      openSystemTunnel(
        server,
        remoteHost: remoteHost,
        remotePort: remotePort,
        onLog: onLog,
        abortTrigger: abortTrigger,
        executable: executable,
      );
}

// ssh before 9.6 hands %h and %r to a ProxyCommand's shell unescaped.
final _unsafeInHost = RegExp(r'''[\s'"`$;&|<>(){}\\/]|[\x00-\x1f]''');
final _unsafeInUser = RegExp(r'''[\s'"`$;&|<>(){}/]|[\x00-\x1f]''');

/// [SystemSshClient.openTunnel], with the parts tests replace.
Future<SshTunnel> openSystemTunnel(
  SshTarget server, {
  required String remoteHost,
  required int remotePort,
  void Function(String line)? onLog,
  Future<void>? abortTrigger,
  String executable = 'ssh',
  Future<int> Function() freePort = pickFreePort,
  Duration configTimeout = const Duration(seconds: 5),
}) async {
  if (server.host.startsWith('-') || server.host.contains(_unsafeInHost)) {
    throw ArgumentError.value(server.host, 'server', 'is not a valid host');
  }
  if (server.user case final user?
      when user.startsWith('-') || user.contains(_unsafeInUser)) {
    throw ArgumentError.value(user, 'server', 'is not a valid user');
  }
  if (remoteHost.contains(_unsafeInHost)) {
    throw ArgumentError.value(remoteHost, 'remoteHost', 'is not a valid host');
  }

  var isAborted = false;
  unawaited(abortTrigger?.then((_) => isAborted = true, onError: (_) {}));

  final ssh = resolveExecutable(executable);
  final config = await resolveConfig(
    server,
    executable: ssh,
    timeout: configTimeout,
    abortTrigger: abortTrigger,
  );
  if (config['clearallforwardings'] == 'yes') {
    throw SshException(
      '~/.ssh/config sets ClearAllForwardings for ${server.host}, '
      'which drops the tunnel',
    );
  }

  for (var attempt = 1;; attempt++) {
    if (isAborted) throw const SshTunnelAbortedException();

    final localPort = await freePort();
    if (isAborted) throw const SshTunnelAbortedException();

    final command = sshCommand(
      server,
      remoteHost: remoteHost,
      remotePort: remotePort,
      localPort: localPort,
      config: config,
      executable: ssh,
    );
    logger.info(command.join(' '));

    try {
      return await SystemSshTunnel.attach(
        await startWatched(command),
        localPort: localPort,
        onLog: onLog,
        abortTrigger: abortTrigger,
      );
    } on SshTunnelException catch (exception) {
      // sh's code for a missing command; Windows fails to start instead.
      if (exception.exitCode == 127) throw const SshNotFoundException();
      // Another process can take the port before ssh binds it.
      if (attempt == 3 || await isPortFree(localPort)) rethrow;
    }
  }
}
