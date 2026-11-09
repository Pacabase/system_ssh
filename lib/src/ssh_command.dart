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

void checkLocalPort(int port) => checkPort(port, 'localPort');

void checkPort(int port, String name) {
  if (port < 1 || port > 65535) throw RangeError.range(port, 1, 65535, name);
}

List<String> localForward(
  int localPort, {
  required String remoteHost,
  required int remotePort,
}) =>
    ['-L', '127.0.0.1:$localPort:${bracketIPv6(remoteHost)}:$remotePort'];

/// A [remotePort] of 0 has the server pick one.
List<String> remoteForward(
  int remotePort, {
  required String localHost,
  required int localPort,
}) =>
    ['-R', '127.0.0.1:$remotePort:${bracketIPv6(localHost)}:$localPort'];

List<String> dynamicForward(int localPort) => ['-D', '127.0.0.1:$localPort'];

/// A `-o` beats ~/.ssh/config, so options are set only where [config]
/// leaves ssh's default, or where it couldn't be read at all.
List<String> sshCommand(
  SshTarget server, {
  required List<String> forward,
  Map<String, String> config = const {},
  String executable = 'ssh',
}) {
  bool isDefault(String name, String value) =>
      config.isEmpty || config[name] == value;

  return [
    executable,
    '-nNTv',
    ...forward,
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
