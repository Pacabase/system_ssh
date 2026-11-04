import 'dart:io';

import 'ssh_client.dart';

/// Something went wrong opening a tunnel.
///
/// The subclasses say what; this class itself is thrown when the tunnel
/// can't be set up for a reason that isn't ssh's.
class SshException implements Exception {
  const SshException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'SshException: $message';
}

/// No `ssh` executable could be started.
final class SshNotFoundException extends SshException {
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
  String toString() => 'SshNotFoundException: $message';
}

/// The `abortTrigger` passed to [SshClient.openTunnel] completed before the
/// tunnel opened.
final class SshTunnelAbortedException extends SshException {
  const SshTunnelAbortedException() : super('the tunnel was aborted');

  @override
  String toString() => 'SshTunnelAbortedException: $message';
}

/// ssh exited before the tunnel was open.
final class SshTunnelException extends SshException {
  const SshTunnelException(super.message, {this.log = const [], this.exitCode});

  /// Everything ssh wrote while it tried, including `-v` progress, as of
  /// when it exited.
  final List<String> log;

  /// ssh's exit code, if it exited.
  final int? exitCode;

  @override
  String toString() => 'SshTunnelException: $message';
}

/// The `127.0.0.1` port asked of [SshClient.openTunnel] is taken.
final class SshPortInUseException extends SshException {
  const SshPortInUseException(this.port)
      : super('127.0.0.1:$port is already in use');

  /// The port that is taken.
  final int port;

  @override
  String toString() => 'SshPortInUseException: $message';
}
