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

// ssh reads a forward without a `/` as a host, splits it at `:`, and newer
// versions expand `%` tokens and `${VAR}` in socket paths.
final _unsafeInSocket = RegExp(r'[:%$]|[\x00-\x1f]');

void checkSocketPath(String path, String name) {
  if (!path.startsWith('/') || path.contains(_unsafeInSocket)) {
    throw ArgumentError.value(path, name, 'is not an absolute socket path');
  }
}

List<String> localForwardToSocket(
  int localPort, {
  required String remoteSocket,
}) =>
    ['-L', '127.0.0.1:$localPort:$remoteSocket'];

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
///
/// With a [masterSocket], ssh serves the forwards `-O forward` adds there,
/// for this process alone; without one, it serves nothing but [forward].
List<String> sshCommand(
  SshTarget server, {
  required List<String> forward,
  Map<String, String> config = const {},
  String executable = 'ssh',
  String? masterSocket,
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
    if (masterSocket case final socket?) ...[
      ...['-o', 'ControlMaster=yes'],
      ...['-o', 'ControlPath=${controlPath(socket)}'],
      ...['-o', 'ControlPersist=no'],
    ] else ...[
      '-o',
      'ControlPath=none'
    ],
    // No terminal answers a password prompt here; fail instead of waiting.
    if (isDefault('batchmode', 'no')) ...['-o', 'BatchMode=yes'],
    // No terminal answers ssh's unknown-host prompt; the caller asks instead.
    if (isDefault('stricthostkeychecking', 'ask')) ...[
      '-o',
      'StrictHostKeyChecking=yes',
    ],
    if (isDefault('connecttimeout', 'none')) ...['-o', 'ConnectTimeout=15'],
    if (isDefault('serveraliveinterval', '0')) ...[
      '-o',
      'ServerAliveInterval=15',
    ],
    ...destinationArguments(server),
  ];
}

/// `ssh -O <operation>` for [forward] on the master at [masterSocket]. It
/// reads no config: ssh would send the config's own forwards with each
/// operation, and a `ControlMaster yes` there has it skip the operation and
/// log in itself.
List<String> muxCommand(
  SshTarget server, {
  required String operation,
  required List<String> forward,
  required String masterSocket,
  String executable = 'ssh',
}) =>
    [
      executable,
      ...['-F', 'none'],
      ...['-o', 'ControlMaster=no'],
      ...['-o', 'ControlPath=${controlPath(masterSocket)}'],
      ...['-o', 'BatchMode=yes'],
      ...['-O', operation],
      ...forward,
      ...destinationArguments(server),
    ];

/// ssh splits an option's value at a space unless it's quoted, and expands
/// `%` tokens in a ControlPath. It has no escape for `$` or `"`, so the
/// socket's directory is picked without them.
String controlPath(String socket) => '"${socket.replaceAll('%', '%%')}"';
