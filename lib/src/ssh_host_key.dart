import 'exceptions.dart';
import 'ssh_client.dart';

/// A server's host key, as ssh names it: what an app shows the user before
/// they trust it with [SshClient.trustHostKey].
///
/// It comes from an [SshUnknownHostKeyException] or an
/// [SshHostKeyChangedException]; a fake [SshClient] builds one to act them out.
final class SshHostKey {
  /// The key [host] offers, of [type], with [fingerprint].
  ///
  /// ```dart
  /// const SshHostKey(
  ///   host: '[ssh.example.com]:2222',
  ///   type: 'ED25519',
  ///   fingerprint: 'SHA256:4Q0Hx2v6PZ9dW1yYk0r6hN1m1bGq9cYw8u2bq3Jm8sY',
  /// );
  /// ```
  const SshHostKey({
    required this.host,
    required this.type,
    required this.fingerprint,
  });

  /// The host as `known_hosts` names it: the host name, `[host]:port` for a
  /// port other than 22, or the config's `HostKeyAlias`.
  final String host;

  /// The key's type as `ssh-keygen -l` prints it, such as `ED25519`, `ECDSA`
  /// or `RSA`.
  final String type;

  /// The key's fingerprint as ssh prints it, such as `SHA256:…`, or `MD5:…`
  /// when the config sets `FingerprintHash md5`.
  final String fingerprint;

  @override
  bool operator ==(Object other) =>
      other is SshHostKey &&
      other.host == host &&
      other.type == type &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(host, type, fingerprint);

  @override
  String toString() => 'SshHostKey($host $type $fingerprint)';
}
