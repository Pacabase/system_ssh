import 'forwards.dart';
import 'ssh_target.dart';

String bracketIPv6(String host) =>
    host.contains(':') && !host.startsWith('[') ? '[$host]' : host;

/// `-p`, `-l`, the key and the host, as both `ssh -G` and the tunnel pass
/// them.
List<String> destinationArguments(SshTarget server) => [
  if (server.port case final port?) ...['-p', '$port'],
  if (server.user case final user?) ...['-l', user],
  ...identityArguments(server),
  '--',
  server.host,
];

/// `-i` and `IdentitiesOnly=yes` for [SshTarget.identityFile], or nothing.
List<String> identityArguments(SshTarget server) => [
  // ssh reads %-tokens in the path, and %% as a plain %.
  if (server.identityFile case final file?) ...[
    '-i',
    file.replaceAll('%', '%%'),
    '-o',
    'IdentitiesOnly=yes',
  ],
];

// ssh before 9.6 hands %h and %r to a ProxyCommand's shell unescaped, and a
// forward reads a `/` as the start of a socket path.
final _unsafeInHost = RegExp(r'''[\s'"`$;&|<>(){}\\/]|[\x00-\x1f]''');

void checkHost(String host, String name) {
  if (host.contains(_unsafeInHost)) {
    throw ArgumentError.value(host, name, 'is not a valid host');
  }
}

void checkLocalPort(int port) => checkPort(port, 'localPort');

/// A forward listens on an IP address; ssh would look a name up, or bind
/// every address for `*`.
void checkBindAddress(String address) {
  try {
    address.contains(':')
        ? Uri.parseIPv6Address(address)
        : Uri.parseIPv4Address(address);
  } on FormatException {
    throw ArgumentError.value(address, 'bindAddress', 'is not an IP address');
  }
}

void checkPort(int port, String name) {
  if (port < 1 || port > 65535) throw RangeError.range(port, 1, 65535, name);
}

// ssh reads a forward without a `/` as a host, splits it at `:`, and newer
// versions expand `%` tokens and `${VAR}` in socket paths.
final _unsafeInSocket = RegExp(r'[:%$]|[\x00-\x1f]');

void checkSocketPath(String path, String name) {
  if (!path.startsWith('/') || path.contains(_unsafeInSocket)) {
    throw ArgumentError.value(path, name, 'is not an absolute socket path');
  }
}

/// A `-o` beats ~/.ssh/config, so options are set only where [config]
/// leaves ssh's default, or where it couldn't be read at all.
///
/// With a [masterSocket], ssh serves the forwards `-O forward` adds there,
/// for this process alone; without one, it serves nothing but [forward].
///
/// With [prompts], ssh may ask through `SSH_ASKPASS`, which the caller sets.
List<String> sshCommand(
  SshTarget server, {
  required Forward? forward,
  Map<String, String> config = const {},
  String executable = 'ssh',
  String? masterSocket,
  bool prompts = false,
}) {
  bool isDefault(String name, String value) =>
      config.isEmpty || config[name] == value;

  return [
    executable,
    '-nNTv',
    ...?forward?.arguments,
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
      'ControlPath=none',
    ],
    // No terminal answers a password prompt here; fail instead of waiting.
    if (!prompts && isDefault('batchmode', 'no')) ...['-o', 'BatchMode=yes'],
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
  required Forward forward,
  required String masterSocket,
  String executable = 'ssh',
}) => [
  executable,
  ...['-F', 'none'],
  ...['-o', 'ControlMaster=no'],
  ...['-o', 'ControlPath=${controlPath(masterSocket)}'],
  ...['-o', 'BatchMode=yes'],
  ...['-O', operation],
  ...forward.arguments,
  ...destinationArguments(server),
];

/// ssh splits an option's value at a space unless it's quoted, and expands
/// `%` tokens in a ControlPath. It has no escape for `$` or `"`, so the
/// socket's directory is picked without them.
String controlPath(String socket) => '"${socket.replaceAll('%', '%%')}"';
