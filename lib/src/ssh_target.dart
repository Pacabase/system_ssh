import 'ssh_command.dart';

/// The SSH server a tunnel goes through.
///
/// A null [port] or [user] is left to `~/.ssh/config`, and [host] may be a
/// `Host` alias from it.
final class SshTarget {
  /// The server at [host], with [port] and [user] left to `~/.ssh/config`
  /// unless given.
  ///
  /// ```dart
  /// const SshTarget('ssh.example.com', port: 2222, user: 'deploy');
  /// ```
  const SshTarget(this.host, {this.port, this.user});

  /// A host name, address or `~/.ssh/config` alias.
  final String host;

  /// The SSH port, or null for the config's (22 by default).
  final int? port;

  /// The user to log in as, or null for the config's (your own by default).
  final String? user;

  @override
  bool operator ==(Object other) =>
      other is SshTarget &&
      other.host == host &&
      other.port == port &&
      other.user == user;

  @override
  int get hashCode => Object.hash(host, port, user);

  @override
  String toString() {
    final address = port == null ? host : bracketIPv6(host);

    return 'SshTarget(${user == null ? '' : '$user@'}$address'
        '${port == null ? '' : ':$port'})';
  }
}
