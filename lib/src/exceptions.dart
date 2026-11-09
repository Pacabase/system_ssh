import 'dart:io';

import 'ssh_client.dart';

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
  /// An error that tells the user how to get ssh: on Windows, to add
  /// "OpenSSH Client" under Optional features; elsewhere, to install OpenSSH.
  factory SshNotFoundException() => Platform.isWindows
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

/// The `127.0.0.1` port asked of [SshClient.openTunnel],
/// [SshClient.openSocketTunnel] or [SshClient.openSocksProxy] is taken.
final class SshPortInUseException extends SshException {
  /// An error saying [port] on `127.0.0.1` is already in use.
  const SshPortInUseException(this.port)
      : super('127.0.0.1:$port is already in use');

  /// The port that is taken.
  final int port;

  @override
  bool get isPermanent => true;

  @override
  String toString() => 'SshPortInUseException: $message';
}
