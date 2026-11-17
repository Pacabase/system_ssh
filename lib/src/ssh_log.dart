import 'ssh_client.dart';

/// A line ssh wrote, by what it means; switch on the subclass to act on one.
///
/// It's information: a tunnel that can't open throws, and one that drops
/// fails [SshForward.done]. A major version may split new kinds out of
/// [SshMessage], which an exhaustive `switch` then has to name.
sealed class SshLog {
  const SshLog(this.line);

  /// ssh's line as it wrote it, for a log.
  final String line;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType && other is SshLog && other.line == line;

  @override
  int get hashCode => Object.hash(runtimeType, line);
}

/// ssh's `-v` progress while it connects, such as
/// `debug1: Connecting to ssh.example.com port 22.`
final class SshProgress extends SshLog {
  /// An entry for [line], as a fake [SshClient] would report it.
  const SshProgress(super.line);

  @override
  String toString() => 'SshProgress($line)';
}

/// Anything else ssh says: an error while it connects, or a warning once the
/// tunnel is open.
final class SshMessage extends SshLog {
  /// An entry for [line], as a fake [SshClient] would report it.
  const SshMessage(super.line);

  @override
  String toString() => 'SshMessage($line)';
}

/// A connection through the open tunnel that couldn't be forwarded, while the
/// tunnel itself stays open; switch on the subclass for why.
sealed class SshForwardFailed extends SshLog {
  const SshForwardFailed(super.line, {required this.reason});

  /// ssh's reason, such as `Connection refused` or
  /// `administratively prohibited`.
  final String reason;

  @override
  bool operator ==(Object other) =>
      super == other && other is SshForwardFailed && other.reason == reason;

  @override
  int get hashCode => Object.hash(runtimeType, line, reason);
}

/// Any failure but a prohibited one: usually nothing at the destination took
/// the connection, which refused, timed out or had no route from the server,
/// and sometimes the server was short of resources.
final class SshForwardUnreachable extends SshForwardFailed {
  /// An entry for [line], failed for [reason], as a fake [SshClient] would
  /// report it.
  const SshForwardUnreachable(super.line, {required super.reason});

  @override
  String toString() => 'SshForwardUnreachable($line)';
}

/// The server's config forbids the connection, such as a `PermitOpen` that
/// doesn't list the destination.
///
/// ```dart
/// onLog: (log) {
///   if (log is SshForwardProhibited) {
///     print("The server doesn't allow this tunnel.");
///   }
/// },
/// ```
final class SshForwardProhibited extends SshForwardFailed {
  /// An entry for [line], as a fake [SshClient] would report it.
  const SshForwardProhibited(super.line)
      : super(reason: 'administratively prohibited');

  @override
  String toString() => 'SshForwardProhibited($line)';
}
