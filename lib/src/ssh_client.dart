import 'exceptions.dart';
import 'ssh_host_key.dart';
import 'ssh_log.dart';
import 'ssh_target.dart';

/// A forward that is open: an [SshTunnel] (a local forward, to a port or a
/// Unix socket, or a SOCKS proxy) or an [SshRemoteTunnel]. Code that only
/// waits on or closes what it opened, whichever kind, can take an
/// [SshForward]:
///
/// ```dart
/// Future<void> closeAll(Iterable<SshForward> forwards) =>
///     Future.wait(forwards.map((forward) => forward.close()));
/// ```
abstract interface class SshForward {
  /// Completes when [close] stops ssh. When ssh exits on its own, because the
  /// connection dropped, it fails with an [SshException] saying why, usually
  /// an [SshDroppedException].
  Future<void> get done;

  /// Stops ssh. Closing again does nothing.
  Future<void> close();
}

/// An open tunnel: connections to [localPort], on the address it was opened
/// to listen on (`127.0.0.1` by default), reach the remote host and port it
/// was opened to, or, for a SOCKS proxy, the ones they ask for.
abstract interface class SshTunnel implements SshForward {
  /// The port to connect to, on the address the tunnel was opened to listen
  /// on.
  int get localPort;
}

/// An open remote forward: connections to `127.0.0.1:`[remotePort] on the
/// server reach the host and port on this side it was opened to.
abstract interface class SshRemoteTunnel implements SshForward {
  /// The port on the server's `127.0.0.1` that reaches back here, until
  /// [close] stops ssh and the server frees it.
  int get remotePort;
}

/// Opens SSH tunnels (local port forwards, to a host and port or a Unix
/// socket), remote forwards and SOCKS proxies (dynamic forwards). An interface, so an app can swap in a fake in its
/// tests.
abstract interface class SshClient {
  /// Forwards [localPort] on [bindAddress], or a free port when it is null,
  /// through [server] to [remoteHost]:[remotePort], as [server] sees them.
  ///
  /// ```dart
  /// final tunnel = await client.openTunnel(
  ///   const SshTarget('ssh.example.com'),
  ///   remoteHost: 'db.example.com',
  ///   remotePort: 5432,
  /// );
  /// ```
  ///
  /// It listens on [bindAddress], an IP address of this computer:
  /// `127.0.0.1` by default, so only this computer can use it. Another
  /// address, such as Docker's bridge `172.17.0.1` on Linux, `0.0.0.0` for
  /// every IPv4 network or `::` for every IPv6 one, lets whatever can reach
  /// it use the tunnel, with no login of its own.
  ///
  /// [onLog] gets an [SshLog] for each non-blank line ssh writes while it
  /// connects, then, until [SshTunnel.close], everything but [SshProgress] and
  /// [SshLoginStarted]:
  /// its warnings, and an [SshForwardFailed] for each connection through the
  /// open tunnel that couldn't be forwarded, such as one the destination
  /// refused. Windows' sshd closes such a connection without saying, so there
  /// it isn't reported. The tunnel's own failures aren't logs: they're thrown,
  /// or fail [SshTunnel.done].
  /// Completing [abortTrigger] before the tunnel is open stops ssh; after,
  /// it is ignored, and [SshTunnel.close] stops it instead.
  ///
  /// Throws:
  /// - [SshNotFoundException] when no `ssh` can be started.
  /// - Another [SshException] when ssh exits before the forward is up, or it
  ///   can't be set up: the class its reason calls for, such as an
  ///   [SshLoginRefusedException] or [SshUnreachableException], else an
  ///   [SshFailedException].
  /// - [SshUnknownHostKeyException] when the server's host key isn't in
  ///   `known_hosts` yet and the config leaves `StrictHostKeyChecking` at
  ///   `ask`; see [trustHostKey].
  /// - [SshHostKeyChangedException] when the server's host key isn't the one
  ///   `known_hosts` holds for it.
  /// - [SshTunnelAbortedException] when [abortTrigger] completes first.
  /// - [SshPortInUseException] when [localPort] is taken.
  /// - [SshAddressUnavailableException] when [bindAddress] isn't an address
  ///   of this computer.
  /// - [ArgumentError] for a host or user ssh could misread, such as one
  ///   starting with `-` or holding spaces or shell characters, a
  ///   [bindAddress] that isn't an IP address, or a [localPort] outside 1 to
  ///   65535.
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  });

  /// Forwards [localPort] on [bindAddress], or a free port when it is null,
  /// to the Unix socket at [remoteSocket] on [server], such as a Docker or
  /// PostgreSQL socket.
  ///
  /// ```dart
  /// final tunnel = await client.openSocketTunnel(
  ///   const SshTarget('ssh.example.com'),
  ///   remoteSocket: '/var/run/docker.sock',
  /// );
  /// // DOCKER_HOST=tcp://127.0.0.1:${tunnel.localPort}
  /// ```
  ///
  /// The server needs an sshd that serves Unix sockets, as OpenSSH does on
  /// Linux and macOS, and a login allowed to open [remoteSocket]. A
  /// connection it can't make comes to [onLog] as an [SshForwardFailed].
  /// [bindAddress], [onLog] and [abortTrigger] otherwise work as in
  /// [openTunnel].
  ///
  /// Throws as [openTunnel] does, and an [ArgumentError] for a
  /// [remoteSocket] that isn't an absolute path, or holds `:`, `%` or `$`,
  /// which ssh would misread.
  Future<SshTunnel> openSocketTunnel(
    SshTarget server, {
    required String remoteSocket,
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  });

  /// Has [server] listen on `127.0.0.1:`[remotePort], or a port it picks
  /// when that is null, and forwards each connection back to
  /// [localHost]:[localPort], as this machine sees them: `ssh -R`.
  ///
  /// ```dart
  /// final tunnel = await client.openRemoteTunnel(
  ///   const SshTarget('ssh.example.com'),
  ///   localPort: 3000,
  ///   remotePort: 8080,
  /// );
  /// ```
  ///
  /// The server's port is on its loopback only, unless its sshd sets
  /// `GatewayPorts yes`. [onLog] and [abortTrigger] work as in [openTunnel],
  /// except that a connection that can't reach [localHost] comes as an
  /// [SshMessage].
  ///
  /// Throws:
  /// - [SshNotFoundException] when no `ssh` can be started.
  /// - [SshRemotePortRefusedException] when the server won't listen on
  ///   [remotePort], or on a remote forward the user's config adds: it's
  ///   taken there, or its sshd doesn't allow forwarding.
  /// - Another [SshException] when ssh exits before the forward is up: the
  ///   class its reason calls for, else an [SshFailedException].
  /// - [SshDuplicateForwardException] with `shareConnections`, when another
  ///   open tunnel on the server already has the same forward.
  /// - [SshUnknownHostKeyException] when the server's host key isn't in
  ///   `known_hosts` yet and the config leaves `StrictHostKeyChecking` at
  ///   `ask`; see [trustHostKey].
  /// - [SshHostKeyChangedException] when the server's host key isn't the one
  ///   `known_hosts` holds for it.
  /// - [SshTunnelAbortedException] when [abortTrigger] completes first.
  /// - [ArgumentError] for a host or user ssh could misread, such as one
  ///   starting with `-` or holding spaces or shell characters, or a
  ///   [localPort] or [remotePort] outside 1 to 65535.
  Future<SshRemoteTunnel> openRemoteTunnel(
    SshTarget server, {
    String localHost = 'localhost',
    required int localPort,
    int? remotePort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  });

  /// Serves a SOCKS5 proxy on [bindAddress]:[localPort], or a free port when
  /// it is null, whose connections [server] makes.
  ///
  /// ```dart
  /// final proxy = await client.openSocksProxy(
  ///   const SshTarget('ssh.example.com'),
  /// );
  /// ```
  ///
  /// [bindAddress], [onLog] and [abortTrigger] work as in [openTunnel].
  ///
  /// Throws:
  /// - [SshNotFoundException] when no `ssh` can be started.
  /// - Another [SshException] when ssh exits before the proxy is up, or it
  ///   can't be set up: the class its reason calls for, else an
  ///   [SshFailedException].
  /// - [SshUnknownHostKeyException] when the server's host key isn't in
  ///   `known_hosts` yet and the config leaves `StrictHostKeyChecking` at
  ///   `ask`; see [trustHostKey].
  /// - [SshHostKeyChangedException] when the server's host key isn't the one
  ///   `known_hosts` holds for it.
  /// - [SshTunnelAbortedException] when [abortTrigger] completes first.
  /// - [SshPortInUseException] when [localPort] is taken.
  /// - [SshAddressUnavailableException] when [bindAddress] isn't an address
  ///   of this computer.
  /// - [ArgumentError] for a host or user ssh could misread, such as one
  ///   starting with `-` or holding spaces or shell characters, a
  ///   [bindAddress] that isn't an IP address, or a [localPort] outside 1 to
  ///   65535.
  Future<SshTunnel> openSocksProxy(
    SshTarget server, {
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  });

  /// The hosts named in `~/.ssh/config` and the files it includes, for
  /// offering them to pick from: aliases, not `*` patterns or `!` negations.
  /// Empty when there is no config.
  Future<List<String>> configuredHosts();

  /// Adds [hostKey], from an [SshUnknownHostKeyException], to the user's
  /// `known_hosts`, once the user has checked its fingerprint, so tunnels to
  /// [server] open from then on, and a later change to the key fails with an
  /// [SshHostKeyChangedException].
  ///
  /// It connects to [server] again to read the key, but doesn't log in, and
  /// writes it only if the key ssh gets has [hostKey]'s fingerprint. ssh writes the
  /// entry as `StrictHostKeyChecking accept-new` would, hashed when the
  /// config sets `HashKnownHosts`, in the first `UserKnownHostsFile` the
  /// config names (`~/.ssh/known_hosts` by default).
  ///
  /// ```dart
  /// await client.trustHostKey(server, exception.hostKey);
  /// ```
  ///
  /// Completing [abortTrigger] first stops it, and nothing is written.
  ///
  /// Throws:
  /// - [SshUnknownHostKeyException] with the key the server offers, when it
  ///   isn't [hostKey]: ask the user about that one instead.
  /// - [SshHostKeyChangedException] when `known_hosts` already holds another
  ///   key for [server].
  /// - Another [SshException] when ssh can't read the server's key: the
  ///   class its reason calls for, such as an [SshHostNotFoundException] or,
  ///   when it doesn't answer in time, an [SshUnreachableException].
  /// - [SshTunnelAbortedException] when [abortTrigger] completes first.
  /// - [SshNotFoundException] when no `ssh` can be started.
  /// - [SshFailedException] when the key can't be written to `known_hosts`.
  /// - [ArgumentError] for a host or user ssh could misread, as
  ///   [openTunnel] rejects.
  Future<void> trustHostKey(
    SshTarget server,
    SshHostKey hostKey, {
    Future<void>? abortTrigger,
  });
}
