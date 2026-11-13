import 'ssh_client.dart';
import 'ssh_host_key.dart';

/// Something went wrong opening a tunnel.
///
/// The subclasses say what; this class itself is thrown when the tunnel
/// can't be set up for a reason that isn't ssh's.
final class SshException implements Exception {
  /// An error that says [message].
  const SshException(this.message);

  /// What went wrong.
  final String message;

  /// Whether trying again can't work until the user changes something, such
  /// as a host key, a login, the ssh config or a port in use. A dropped
  /// connection, a timeout or a host that doesn't resolve while offline isn't.
  bool get isPermanent => false;

  @override
  String toString() => 'SshException: $message';
}

/// No `ssh` executable could be started.
final class SshNotFoundException extends SshException {
  /// An error that tells the user how to get ssh: [onWindows], to add
  /// "OpenSSH Client" under Optional features; otherwise, to install OpenSSH.
  factory SshNotFoundException({bool onWindows = false}) => onWindows
      ? const SshNotFoundException._(
          'ssh was not found; add "OpenSSH Client" in Settings under '
          'Optional features',
        )
      : const SshNotFoundException._(
          'ssh was not found; install OpenSSH and put it on the PATH',
        );

  const SshNotFoundException._(super.message);

  @override
  bool get isPermanent => true;

  @override
  String toString() => 'SshNotFoundException: $message';
}

/// The `abortTrigger` passed to [SshClient.openTunnel],
/// [SshClient.openSocketTunnel], [SshClient.openRemoteTunnel] or
/// [SshClient.openSocksProxy] completed before the tunnel opened.
final class SshTunnelAbortedException extends SshException {
  /// An error saying the tunnel was aborted.
  const SshTunnelAbortedException() : super('the tunnel was aborted');

  @override
  String toString() => 'SshTunnelAbortedException: $message';
}

/// ssh exited on its own: before the tunnel was open, when opening it, or
/// after, when the connection dropped (from [SshTunnel.done] or
/// [SshRemoteTunnel.done]).
final class SshTunnelException extends SshException {
  /// An error that says [message], which is what a fake [SshClient] throws
  /// to act out a failure. [log] defaults to empty, [exitCode] to null and
  /// [isPermanent] to false.
  ///
  /// ```dart
  /// throw const SshTunnelException(
  ///   'Permission denied (publickey).',
  ///   exitCode: 255,
  ///   isPermanent: true,
  /// );
  /// ```
  const SshTunnelException(
    super.message, {
    this.log = const [],
    this.exitCode,
    this.isPermanent = false,
  });

  @override
  final bool isPermanent;

  /// Everything ssh wrote while it tried, including `-v` progress, as of
  /// when it exited.
  final List<String> log;

  /// ssh's exit code, if it exited.
  final int? exitCode;

  @override
  String toString() => 'SshTunnelException: $message';
}

/// The server's host key isn't in `known_hosts` yet, so ssh refused it rather
/// than trust it unseen.
///
/// Show the user [hostKey], and once they have checked its fingerprint, call
/// [SshClient.trustHostKey] and open the tunnel again:
///
/// ```dart
/// } on SshUnknownHostKeyException catch (exception) {
///   if (await askToTrust(exception.hostKey)) {
///     await client.trustHostKey(server, exception.hostKey);
///     // ...and open the tunnel again.
///   }
/// }
/// ```
///
/// It is thrown only where the user's ssh config leaves
/// `StrictHostKeyChecking` at `ask`, as a terminal would ask there. A config
/// that sets `yes`, `accept-new` or `no` gets what it asks for.
final class SshUnknownHostKeyException extends SshTunnelException {
  /// An error saying the server offers [hostKey], which isn't known yet.
  SshUnknownHostKeyException(this.hostKey, {super.log, super.exitCode})
      : super(
          '${hostKey.host} is not a known host; its ${hostKey.type} key '
          'fingerprint is ${hostKey.fingerprint}',
          isPermanent: true,
        );

  /// The key the server offered.
  final SshHostKey hostKey;

  @override
  String toString() => 'SshUnknownHostKeyException: $message';
}

/// The server offers a host key other than the one `known_hosts` holds for it,
/// or other than the one passed to [SshClient.trustHostKey]: someone may be
/// intercepting the connection, or the server was reinstalled.
///
/// Nothing is trusted or written; trying again can't work until the user
/// removes the old key, such as with `ssh-keygen -R`, after finding out why it
/// changed.
final class SshHostKeyChangedException extends SshTunnelException {
  /// An error saying [hostKey] is what the server offers now.
  SshHostKeyChangedException(this.hostKey, {super.log, super.exitCode})
      : super(
          'the host key for ${hostKey.host} has changed; it now offers the '
          '${hostKey.type} key ${hostKey.fingerprint}',
          isPermanent: true,
        );

  /// The key the server offers now.
  final SshHostKey hostKey;

  @override
  String toString() => 'SshHostKeyChangedException: $message';
}

/// The user's ssh config for the host stops the tunnel from working, for
/// example by setting `ClearAllForwardings`, so trying again can't work until
/// they change it.
final class SshConfigException extends SshException {
  /// An exception saying, in [message], which setting stops the tunnel.
  const SshConfigException(super.message);

  @override
  bool get isPermanent => true;

  @override
  String toString() => 'SshConfigException: $message';
}

/// The port asked of [SshClient.openTunnel], [SshClient.openSocketTunnel] or
/// [SshClient.openSocksProxy] is taken on the address it would listen on.
final class SshPortInUseException extends SshException {
  /// An error saying [port] on [address] is already in use.
  const SshPortInUseException(this.port, {this.address = '127.0.0.1'})
      : super('$address:$port is already in use');

  /// The port that is taken.
  final int port;

  /// The address it is taken on, `127.0.0.1` unless the tunnel asked for
  /// another.
  final String address;

  @override
  bool get isPermanent => true;

  @override
  String toString() => 'SshPortInUseException: $message';
}
