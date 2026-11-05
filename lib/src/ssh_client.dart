import 'exceptions.dart';
import 'ssh_log.dart';
import 'ssh_target.dart';

/// An open tunnel: connections to `127.0.0.1:`[localPort] reach the remote
/// host and port it was opened to, or, for a SOCKS proxy, the ones they ask
/// for.
abstract interface class SshTunnel {
  /// The `127.0.0.1` port to connect to.
  int get localPort;

  /// Completes when [close] stops ssh. When ssh exits on its own, because the
  /// connection dropped, it fails with an [SshTunnelException] saying why.
  Future<void> get done;

  /// Stops ssh. Closing again does nothing.
  Future<void> close();
}

/// Opens SSH tunnels (local port forwards) and SOCKS proxies (dynamic
/// forwards). An interface, so an app can swap in a fake in its tests.
abstract interface class SshClient {
  /// Forwards [localPort] on `127.0.0.1`, or a free port when it is null,
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
  /// [onLog] gets an [SshLog] for each non-blank line ssh writes while it
  /// connects, then, until [SshTunnel.close], everything but [SshProgress]:
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
  /// - [SshTunnelException] when ssh exits before the forward is up.
  /// - [SshTunnelAbortedException] when [abortTrigger] completes first.
  /// - [SshPortInUseException] when [localPort] is taken.
  /// - [SshException] when the tunnel can't be set up for another reason.
  /// - [ArgumentError] for a host or user ssh could misread, such as one
  ///   starting with `-` or holding spaces or shell characters, or a
  ///   [localPort] outside 1 to 65535.
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  });

  /// Serves a SOCKS5 proxy on `127.0.0.1:`[localPort], or a free port when it
  /// is null, whose connections [server] makes.
  ///
  /// ```dart
  /// final proxy = await client.openSocksProxy(
  ///   const SshTarget('ssh.example.com'),
  /// );
  /// ```
  ///
  /// [onLog] and [abortTrigger] work as in [openTunnel].
  ///
  /// Throws:
  /// - [SshNotFoundException] when no `ssh` can be started.
  /// - [SshTunnelException] when ssh exits before the proxy is up.
  /// - [SshTunnelAbortedException] when [abortTrigger] completes first.
  /// - [SshPortInUseException] when [localPort] is taken.
  /// - [SshException] when the proxy can't be set up for another reason.
  /// - [ArgumentError] for a host or user ssh could misread, such as one
  ///   starting with `-` or holding spaces or shell characters, or a
  ///   [localPort] outside 1 to 65535.
  Future<SshTunnel> openSocksProxy(
    SshTarget server, {
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  });

  /// The hosts named in `~/.ssh/config` and the files it includes, for
  /// offering them to pick from: aliases, not `*` patterns or `!` negations.
  /// Empty when there is no config.
  Future<List<String>> configuredHosts();
}
