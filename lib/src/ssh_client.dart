import 'exceptions.dart';
import 'ssh_target.dart';

/// An open tunnel: connections to `127.0.0.1:`[localPort] reach the remote
/// host and port it was opened to.
abstract interface class SshTunnel {
  /// The `127.0.0.1` port to connect to.
  int get localPort;

  /// Completes, never with an error, when ssh exits, whether through [close]
  /// or because the connection dropped.
  Future<void> get done;

  /// Stops ssh. Closing again does nothing.
  Future<void> close();
}

/// Opens SSH tunnels (local port forwards). An interface, so an app can swap
/// in a fake in its tests.
abstract interface class SshClient {
  /// Forwards a free `127.0.0.1` port through [server] to
  /// [remoteHost]:[remotePort], as [server] sees them.
  ///
  /// ```dart
  /// final tunnel = await client.openTunnel(
  ///   const SshTarget('ssh.example.com'),
  ///   remoteHost: 'db.example.com',
  ///   remotePort: 5432,
  /// );
  /// ```
  ///
  /// [onLog] gets each line ssh writes until the tunnel is open. Completing
  /// [abortTrigger] before then stops ssh; once the tunnel is open it is
  /// ignored, and [SshTunnel.close] stops it instead.
  ///
  /// Throws:
  /// - [SshNotFoundException] when no `ssh` can be started.
  /// - [SshTunnelException] when ssh exits before the forward is up.
  /// - [SshTunnelAbortedException] when [abortTrigger] completes first.
  /// - [SshException] when the tunnel can't be set up for another reason.
  /// - [ArgumentError] for a host or user ssh could misread, such as one
  ///   starting with `-` or holding spaces or shell characters.
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    void Function(String line)? onLog,
    Future<void>? abortTrigger,
  });
}
