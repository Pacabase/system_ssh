import 'ssh_command.dart';
import 'ssh_target.dart';

/// The command that opens the same tunnel as `openTunnel` from a terminal,
/// such as `ssh -N -L 127.0.0.1:15432:db.example.com:5432 ssh.example.com`.
///
/// It's for people: it leaves out the options this package adds for a tunnel
/// nobody watches, so ssh can ask for a password or a new host key there.
///
/// Throws an [ArgumentError] for a [server] host starting with `-`, which ssh
/// would read as an option, or a [localPort] outside 1 to 65535.
String tunnelCommand(
  SshTarget server, {
  required String remoteHost,
  required int remotePort,
  required int localPort,
}) {
  checkLocalPort(localPort);
  return _command(
    server,
    localForward(localPort, remoteHost: remoteHost, remotePort: remotePort),
  );
}

/// The command that opens the same tunnel as `openSocketTunnel` from a
/// terminal, such as `ssh -N -L 127.0.0.1:2375:/var/run/docker.sock
/// ssh.example.com`.
///
/// Throws an [ArgumentError] for a [server] host starting with `-`, a
/// [remoteSocket] ssh would misread, or a [localPort] outside 1 to 65535.
String socketTunnelCommand(
  SshTarget server, {
  required String remoteSocket,
  required int localPort,
}) {
  checkLocalPort(localPort);
  checkSocketPath(remoteSocket, 'remoteSocket');
  return _command(
    server,
    localForwardToSocket(localPort, remoteSocket: remoteSocket),
  );
}

/// The command that opens the same remote forward as `openRemoteTunnel` from
/// a terminal, such as `ssh -N -R 127.0.0.1:8080:localhost:3000
/// ssh.example.com`.
///
/// Throws an [ArgumentError] for a [server] host starting with `-`, which ssh
/// would read as an option, or a [localPort] or [remotePort] outside 1 to
/// 65535.
String remoteTunnelCommand(
  SshTarget server, {
  String localHost = 'localhost',
  required int localPort,
  required int remotePort,
}) {
  checkLocalPort(localPort);
  checkPort(remotePort, 'remotePort');
  return _command(
    server,
    remoteForward(remotePort, localHost: localHost, localPort: localPort),
  );
}

/// The command that serves the same SOCKS proxy as `openSocksProxy` from a
/// terminal, such as `ssh -N -D 127.0.0.1:1080 ssh.example.com`.
///
/// Throws an [ArgumentError] for a [server] host starting with `-`, which ssh
/// would read as an option, or a [localPort] outside 1 to 65535.
String socksProxyCommand(SshTarget server, {required int localPort}) {
  checkLocalPort(localPort);
  return _command(server, dynamicForward(localPort));
}

String _command(SshTarget server, List<String> forward) {
  if (server.host.startsWith('-')) {
    throw ArgumentError.value(server.host, 'server', 'is not a valid host');
  }

  return [
    'ssh',
    '-N',
    ...forward,
    if (server.port case final port?) ...['-p', '$port'],
    if (server.user case final user?) '$user@${server.host}' else server.host,
  ].map(_quoted).join(' ');
}

final _plain = RegExp(r'^[A-Za-z0-9@%_+=:,./\[\]-]+$');

String _quoted(String argument) => _plain.hasMatch(argument)
    ? argument
    : "'${argument.replaceAll("'", r"'\''")}'";
