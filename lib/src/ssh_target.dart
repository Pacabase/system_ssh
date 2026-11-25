import 'ssh_command.dart';

/// The SSH server a tunnel goes through.
///
/// A null [port], [user] or [identityFile] is left to `~/.ssh/config`, and
/// [host] may be a `Host` alias from it.
final class SshTarget {
  /// The server at [host], with [port], [user] and [identityFile] left to
  /// `~/.ssh/config` unless given.
  ///
  /// ```dart
  /// const SshTarget('ssh.example.com', port: 2222, user: 'deploy');
  /// const SshTarget('myserver', identityFile: '~/.ssh/id_work');
  /// ```
  const SshTarget(this.host, {this.port, this.user, this.identityFile});

  /// A host name, address or `~/.ssh/config` alias.
  final String host;

  /// The SSH port, or null for the config's (22 by default).
  final int? port;

  /// The user to log in as, or null for the config's (your own by default).
  final String? user;

  /// The private key file to log in with, such as `~/.ssh/id_work`, or null
  /// for the config's keys and your agent's. With it, ssh offers only this
  /// key (`IdentitiesOnly=yes`), from the file or from your agent, so a
  /// server that allows few attempts doesn't refuse you after the others.
  /// A key with a passphrase asks through `onPrompt`, unless your agent
  /// holds it.
  final String? identityFile;

  @override
  bool operator ==(Object other) =>
      other is SshTarget &&
      other.host == host &&
      other.port == port &&
      other.user == user &&
      other.identityFile == identityFile;

  @override
  int get hashCode => Object.hash(host, port, user, identityFile);

  @override
  String toString() {
    final address = port == null ? host : bracketIPv6(host);

    return 'SshTarget(${user == null ? '' : '$user@'}$address'
        '${port == null ? '' : ':$port'}'
        '${identityFile == null ? '' : ', identityFile: $identityFile'})';
  }
}
