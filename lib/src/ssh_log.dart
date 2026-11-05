import 'ssh_client.dart';

/// A line ssh wrote, by what it means; switch on the subclass to act on one.
///
/// It's information: a tunnel that can't open throws, and one that drops
/// fails [SshTunnel.done].
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
  const SshProgress(super.line);

  @override
  String toString() => 'SshProgress($line)';
}

/// Anything else ssh says: an error while it connects, or a warning once the
/// tunnel is open.
final class SshWarning extends SshLog {
  const SshWarning(super.line);

  @override
  String toString() => 'SshWarning($line)';
}

/// A connection through the open tunnel that couldn't be forwarded, while the
/// tunnel itself stays open: nothing listened at the destination, or the
/// server doesn't allow forwarding there.
final class SshConnectionFailed extends SshLog {
  const SshConnectionFailed(super.line, {required this.reason});

  /// Why, such as `Connection refused` or `administratively prohibited`.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is SshConnectionFailed &&
      other.line == line &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(line, reason);

  @override
  String toString() => 'SshConnectionFailed($reason: $line)';
}
