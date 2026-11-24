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
/// it comes as a breaking release with a **Breaking:** CHANGELOG entry; one
/// that only catches the two groups keeps working.
sealed class SshException implements Exception {
  /// An error that says [message], with what ssh wrote in [log] and its
  /// [exitCode].
  const SshException(this.message, {this.log = const [], this.exitCode});

  /// What went wrong, in ssh's words when ssh said why.
  final String message;

  /// Everything ssh wrote while it tried, including `-v` progress, as of when
  /// it exited. Empty when the failure wasn't ssh's.
  final List<String> log;

  /// ssh's exit code, if it exited.
  final int? exitCode;

  // Spelled out, since an obfuscated build renames runtimeType.
  @override
  String toString() => '${switch (this) {
        SshNotFoundException() => 'SshNotFoundException',
        SshConfigException() => 'SshConfigException',
        SshPortInUseException() => 'SshPortInUseException',
        SshDuplicateForwardException() => 'SshDuplicateForwardException',
        SshLoginRefusedException() => 'SshLoginRefusedException',
        SshHostKeyRefusedException() => 'SshHostKeyRefusedException',
        SshUnknownHostKeyException() => 'SshUnknownHostKeyException',
        SshHostKeyChangedException() => 'SshHostKeyChangedException',
        SshHostNotFoundException() => 'SshHostNotFoundException',
        SshUnreachableException() => 'SshUnreachableException',
        SshDroppedException() => 'SshDroppedException',
        SshAddressUnavailableException() => 'SshAddressUnavailableException',
        SshRemotePortRefusedException() => 'SshRemotePortRefusedException',
        SshFailedException() => 'SshFailedException',
        SshTunnelAbortedException() => 'SshTunnelAbortedException',
        SshLoginCancelledException() => 'SshLoginCancelledException',
      }}: $message';
}

/// Trying again can't work until the user changes something: a host key, a
/// login, the ssh config or a port in use.
sealed class SshPermanentException extends SshException {
  /// An error that says [message], with what ssh wrote in [log] and its
  /// [exitCode].
  const SshPermanentException(super.message, {super.log, super.exitCode});
}

/// Trying again may work: the network, the server or this computer may come
/// back, or the failure was a race.
sealed class SshTemporaryException extends SshException {
  /// An error that says [message], with what ssh wrote in [log] and its
  /// [exitCode].
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
}

/// The user's ssh config for the host stops the tunnel: it sets
/// `ClearAllForwardings`, ssh can't read it, for a bad option, a syntax error
/// or the file's owner or permissions, or it allows no algorithm the server
/// offers (`Unable to negotiate`). It also says when the `ssh` installed is
/// too old for an `onPrompt`, which needs OpenSSH 8.4 or newer.
final class SshConfigException extends SshPermanentException {
  /// An error saying, in [message], what in the config stops the tunnel.
  const SshConfigException(super.message, {super.log, super.exitCode});
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
}

/// With `shareConnections`, another open tunnel on this server already has
/// the same remote forward: the same local host and port on the same server
/// port, or both on a port the server picks.
///
/// The shared connection would give both tunnels that one forward, and
/// closing either would close it for both, so the second is refused rather
/// than given a login of its own. Use the tunnel that's open, close it first,
/// or pass another `remotePort` to [SshClient.openRemoteTunnel].
final class SshDuplicateForwardException extends SshPermanentException {
  /// An error saying another tunnel already forwards [forward].
  const SshDuplicateForwardException(this.forward)
      : super('another tunnel on this connection already forwards $forward');

  /// The forward, as ssh takes it after `-R`, such as
  /// `127.0.0.1:8080:localhost:3000`.
  final String forward;
}

/// The server wouldn't listen on a remote forward's port, the one a remote
/// tunnel asked for or one the user's config adds: it's taken there, or its
/// sshd doesn't allow remote forwarding. Trying again can't work until the
/// port is freed there or the server's config changes.
///
/// ```dart
/// throw const SshRemotePortRefusedException(
///   'Error: remote port forwarding failed for listen port 8080',
///   port: 8080,
/// );
/// ```
final class SshRemotePortRefusedException extends SshPermanentException {
  /// An error saying, in [message], that the server refused [port].
  const SshRemotePortRefusedException(
    super.message, {
    required this.port,
    super.log,
    super.exitCode,
  });

  /// The server's port that was refused, or 0 for one the server would pick.
  final int port;
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
}

/// ssh refused a host key that isn't asked about: the user's ssh config sets
/// `StrictHostKeyChecking yes`, or a `ProxyJump` host's key is unknown or
/// changed.
///
/// For the server's own key, where the config leaves `StrictHostKeyChecking`
/// at `ask`, an [SshUnknownHostKeyException] or [SshHostKeyChangedException]
/// comes instead, with the key the server offers.
final class SshHostKeyRefusedException extends SshPermanentException {
  /// An error saying, in [message], why ssh refused the host key.
  const SshHostKeyRefusedException(super.message, {super.log, super.exitCode});
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
}

/// The server's name didn't resolve. That can mean a typo, but also no
/// network yet, so trying again may work.
final class SshHostNotFoundException extends SshTemporaryException {
  /// An error saying, in [message], which name didn't resolve.
  const SshHostNotFoundException(super.message, {super.log, super.exitCode});
}

/// The server didn't answer: the connection was refused, timed out or had no
/// route, or ssh didn't finish a step in time.
final class SshUnreachableException extends SshTemporaryException {
  /// An error saying, in [message], how the server didn't answer.
  const SshUnreachableException(super.message, {super.log, super.exitCode});
}

/// The connection went down: the server closed or reset it, before the login
/// or after, or stopped answering ssh's keepalives. A failed
/// [SshForward.done] says this when ssh's last lines say so.
final class SshDroppedException extends SshTemporaryException {
  /// An error saying, in [message], how the connection went down.
  const SshDroppedException(super.message, {super.log, super.exitCode});
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
}

/// The `abortTrigger` passed to [SshClient.openTunnel],
/// [SshClient.openSocketTunnel], [SshClient.openRemoteTunnel] or
/// [SshClient.openSocksProxy] completed before the tunnel opened.
final class SshTunnelAbortedException extends SshException {
  /// An error saying the tunnel was aborted.
  const SshTunnelAbortedException() : super('the tunnel was aborted');
}

/// The `onPrompt` passed to [SshClient.openTunnel],
/// [SshClient.openSocketTunnel], [SshClient.openRemoteTunnel] or
/// [SshClient.openSocksProxy] answered null, so ssh gave up the login it was
/// asking about.
///
/// The user chose this, so it's neither temporary nor permanent: open the
/// tunnel again when they ask. A wrong answer is an
/// [SshLoginRefusedException] instead.
final class SshLoginCancelledException extends SshException {
  /// An error saying the login was cancelled, with what ssh wrote in [log]
  /// and its [exitCode].
  const SshLoginCancelledException({super.log, super.exitCode})
      : super('the login was cancelled');
}
