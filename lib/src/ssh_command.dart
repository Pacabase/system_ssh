import 'ssh_target.dart';

String bracketIPv6(String host) =>
    host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

/// `-p`, `-l` and the host, as both `ssh -G` and the tunnel pass them.
List<String> destinationArguments(SshTarget server) => [
      if (server.port case final port?) ...['-p', '$port'],
      if (server.user case final user?) ...['-l', user],
      '--',
      server.host,
    ];

/// The `ssh -L` command forwarding `127.0.0.1:`[localPort] to
/// [remoteHost]:[remotePort] through [server].
///
/// A `-o` beats ~/.ssh/config, so options are set only where [config]
/// leaves ssh's default, or where it couldn't be read at all.
List<String> sshCommand(
  SshTarget server, {
  required String remoteHost,
  required int remotePort,
  required int localPort,
  Map<String, String> config = const {},
  String executable = 'ssh',
}) {
  bool isDefault(String name, String value) =>
      config.isEmpty || config[name] == value;

  return [
    executable,
    '-nNTv',
    ...['-L', '127.0.0.1:$localPort:${bracketIPv6(remoteHost)}:$remotePort'],
    ...['-o', 'ExitOnForwardFailure=yes'],
    // This process owns ssh: it must not fork away or serve other sessions.
    if (config['forkafterauthentication'] == 'yes') ...[
      '-o',
      'ForkAfterAuthentication=no',
    ],
    ...['-o', 'ControlPath=none'],
    // No terminal answers a password prompt here; fail instead of waiting.
    if (isDefault('batchmode', 'no')) ...['-o', 'BatchMode=yes'],
    // No terminal answers ssh's unknown-host prompt; a changed key still fails.
    if (isDefault('stricthostkeychecking', 'ask')) ...[
      '-o',
      'StrictHostKeyChecking=accept-new',
    ],
    if (isDefault('connecttimeout', 'none')) ...['-o', 'ConnectTimeout=15'],
    if (isDefault('serveraliveinterval', '0')) ...[
      '-o',
      'ServerAliveInterval=15',
    ],
    ...destinationArguments(server),
  ];
}
