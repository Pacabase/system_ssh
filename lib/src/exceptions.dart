import 'ssh_client.dart';
import 'ssh_host_key.dart';

/// Something went wrong opening a tunnel, or an open one went down.
///
/// Every failure is one of these classes, under [SshPermanentException] when
/// trying again can't work until the user changes something, or
/// [SshTemporaryException] when it can. An app that retries catches the two:
///
/// ```dart
/// try {
///   return await client.openTunnel(server, remoteHost: 'db', remotePort: 5432);
/// } on SshTemporaryException {
///   // Wait a little and try again.
/// } on SshPermanentException catch (exception) {
///   // Stop, and tell the user what to change.
/// }
/// ```
///
/// A `switch` over the classes puts each in the app's own words. A later
/// version may add a class, which breaks a `switch` that names every one, so
/// the CHANGELOG calls that out.
sealed class SshException implements Exception {
  const SshException(this.message, {this.log = const [], this.exitCode});

  /// What went wrong, in ssh's words when ssh said why.
  final String message;

  /// Everything ssh wrote while it tried, including `-v` progress, as of when
  /// it exited. Empty when the failure wasn't ssh's.
  final List<String> log;

  /// ssh's exit code, if it exited.
  final int? exitCode;

  @override
  String toString() => 'SshException: $message';
}

/// Trying again can't work until the user changes something: a host key, a
/// login, the ssh config or a port in use.
sealed class SshPermanentException extends SshException {
  const SshPermanentException(super.message, {super.log, super.exitCode});
}

/// Trying again may work: the network, the server or this computer may come
/// back, or the failure was a race.
sealed class SshTemporaryException extends SshException {
  const SshTemporaryException(super.message, {super.log, super.exitCode});
}

/// No `ssh` executable could be started.
final class SshNotFoundException extends SshPermanentException {
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
  String toString() => 'SshNotFoundException: $message';
}

/// The user's ssh config for the host stops the tunnel: it sets
/// `ClearAllForwardings`, or ssh can't read it, for a bad option, a syntax
/// error or the file's owner or permissions.
final class SshConfigException extends SshPermanentException {
  /// An error saying, in [message], what in the config stops the tunnel.
  const SshConfigException(super.message, {super.log, super.exitCode});

  @override
  String toString() => 'SshConfigException: $message';
}

/// The port asked of [SshClient.openTunnel], [SshClient.openSocketTunnel] or
/// [SshClient.openSocksProxy] is taken on the address it would listen on.
final class SshPortInUseException extends SshPermanentException {
  /// An error saying [port] on [address] is already in use.
  const SshPortInUseException(this.port, {this.address = '127.0.0.1'})
      : super('$address:$port is already in use');

  /// The port that is taken.
  final int port;

  /// The address it is taken on, `127.0.0.1` unless the tunnel asked for
  /// another.
  final String address;

  @override
  String toString() => 'SshPortInUseException: $message';
}

/// The server refused every login ssh tried, such as a key it doesn't know or
/// too many keys offered.
///
/// ```dart
/// throw const SshLoginRefusedException(
///   'Permission denied (publickey).',
///   exitCode: 255,
/// );
/// ```
final class SshLoginRefusedException extends SshPermanentException {
  /// An error saying, in [message], how the server refused the login.
  const SshLoginRefusedException(super.message, {super.log, super.exitCode});

  @override
  String toString() => 'SshLoginRefusedException: $message';
}

/// ssh refused the server's host key, where the user's ssh config sets
/// `StrictHostKeyChecking` to `yes`, or the key differs from `known_hosts`.
///
/// Where the config leaves `StrictHostKeyChecking` at `ask`, an
/// [SshUnknownHostKeyException] or [SshHostKeyChangedException] comes
/// instead, with the key the server offers.
final class SshHostKeyRefusedException extends SshPermanentException {
  /// An error saying, in [message], why ssh refused the host key.
  const SshHostKeyRefusedException(super.message, {super.log, super.exitCode});

  @override
  String toString() => 'SshHostKeyRefusedException: $message';
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
final class SshUnknownHostKeyException extends SshPermanentException {
  /// An error saying the server offers [hostKey], which isn't known yet.
  SshUnknownHostKeyException(this.hostKey, {super.log, super.exitCode})
      : super(
          '${hostKey.host} is not a known host; its ${hostKey.type} key '
          'fingerprint is ${hostKey.fingerprint}',
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
final class SshHostKeyChangedException extends SshPermanentException {
  /// An error saying [hostKey] is what the server offers now.
  SshHostKeyChangedException(this.hostKey, {super.log, super.exitCode})
      : super(
          'the host key for ${hostKey.host} has changed; it now offers the '
          '${hostKey.type} key ${hostKey.fingerprint}',
        );

  /// The key the server offers now.
  final SshHostKey hostKey;

  @override
  String toString() => 'SshHostKeyChangedException: $message';
}

/// The server's name didn't resolve. That can mean a typo, but also no
/// network yet, so trying again may work.
final class SshHostNotFoundException extends SshTemporaryException {
  /// An error saying, in [message], which name didn't resolve.
  const SshHostNotFoundException(super.message, {super.log, super.exitCode});

  @override
  String toString() => 'SshHostNotFoundException: $message';
}

/// The server didn't answer: the connection was refused, timed out or had no
/// route, or ssh didn't finish a step in time.
final class SshUnreachableException extends SshTemporaryException {
  /// An error saying, in [message], how the server didn't answer.
  const SshUnreachableException(super.message, {super.log, super.exitCode});

  @override
  String toString() => 'SshUnreachableException: $message';
}

/// The connection was up and went down: the server closed or reset it, or
/// stopped answering ssh's keepalives. A failed [SshForward.done] says this
/// when ssh's last lines say so.
final class SshDroppedException extends SshTemporaryException {
  /// An error saying, in [message], how the connection went down.
  const SshDroppedException(super.message, {super.log, super.exitCode});

  @override
  String toString() => 'SshDroppedException: $message';
}

/// The `bindAddress` a tunnel was asked to listen on isn't an address of this
/// computer, at least not yet: a network such as Docker's bridge may come up
/// later.
final class SshAddressUnavailableException extends SshTemporaryException {
  /// An error saying [address] isn't on this computer.
  const SshAddressUnavailableException(this.address)
      : super("$address isn't an address of this computer");

  /// The address the tunnel was asked to listen on.
  final String address;

  @override
  String toString() => 'SshAddressUnavailableException: $message';
}

/// Any other failure, with ssh's words in [message] when it said why. Trying
/// again may work.
///
/// ```dart
/// throw const SshFailedException('ssh exited with code 255', exitCode: 255);
/// ```
final class SshFailedException extends SshTemporaryException {
  /// An error that says [message].
  const SshFailedException(super.message, {super.log, super.exitCode});

  @override
  String toString() => 'SshFailedException: $message';
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
