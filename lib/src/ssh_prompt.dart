import 'dart:async';

/// Something ssh asks while it logs in, for the app to answer or cancel
/// through an `onPrompt`: an [SshPassphrasePrompt] for a key file, an
/// [SshPasswordPrompt], or an [SshCodePrompt] for anything the server asks,
/// such as a 2FA code.
///
/// ```dart
/// onPrompt: (prompt) => switch (prompt) {
///   SshPassphrasePrompt(:final keyPath) => askForPassphrase(keyPath),
///   SshPasswordPrompt() => askForPassword(prompt.text),
///   SshCodePrompt() => askForCode(prompt.text),
/// },
/// ```
sealed class SshPrompt {
  const SshPrompt(this.text, {this.isVerified = true, Future<void>? withdrawn})
    : _withdrawn = withdrawn;

  /// The prompt as ssh shows it, such as `alice@ssh.example.com's password: `.
  /// For an [SshCodePrompt] these are the server's own words, so show them as
  /// plain text, never as markup.
  final String text;

  /// Whether ssh tells a server's questions apart from its own, so the kind
  /// is sure. False before OpenSSH 8.5, which doesn't put `(user@host)` in
  /// front of a server's question, so a server could word one as ssh's own,
  /// such as a passphrase prompt. A terminal shows those prompts the same
  /// way; an app may want to say where the prompt may come from, or not keep
  /// what's typed.
  final bool isVerified;

  /// Completes once ssh no longer waits for the answer: the login went on
  /// another way, failed, or was aborted. Close the dialog then; an answer
  /// after it goes nowhere. With `shareConnections`, a login another tunnel
  /// waits on goes on after the tunnel that asked closes, so this, not that
  /// tunnel's open call, says when the prompt is over.
  ///
  /// ```dart
  /// onPrompt: (prompt) {
  ///   final dialog = showPromptDialog(prompt);
  ///   prompt.withdrawn.then((_) => dialog.close());
  ///   return dialog.answer;
  /// },
  /// ```
  Future<void> get withdrawn => _withdrawn ?? _never;
  final Future<void>? _withdrawn;
  static final _never = Completer<void>().future;

  @override
  bool operator ==(Object other) =>
      other is SshPrompt &&
      other.runtimeType == runtimeType &&
      other.text == text &&
      other.isVerified == isVerified;

  @override
  int get hashCode => Object.hash(runtimeType, text, isVerified);

  // Spelled out, since an obfuscated build renames runtimeType.
  @override
  String toString() =>
      '${switch (this) {
        SshPassphrasePrompt() => 'SshPassphrasePrompt',
        SshPasswordPrompt() => 'SshPasswordPrompt',
        SshCodePrompt() => 'SshCodePrompt',
      }}($text)';
}

/// ssh asks for the passphrase of the key file at [keyPath].
///
/// ```dart
/// const SshPassphrasePrompt(
///   "Enter passphrase for key '/home/alice/.ssh/id_ed25519': ",
///   keyPath: '/home/alice/.ssh/id_ed25519',
/// );
/// ```
final class SshPassphrasePrompt extends SshPrompt {
  /// ssh's [text], asking for the passphrase of [keyPath].
  const SshPassphrasePrompt(
    super.text, {
    required this.keyPath,
    super.isVerified,
    super.withdrawn,
  });

  /// The key file, as ssh names it, cut short past 100 characters.
  final String keyPath;
}

/// ssh asks for the user's password on a server, or a `ProxyJump` host on
/// the way.
final class SshPasswordPrompt extends SshPrompt {
  /// ssh's [text], such as `alice@ssh.example.com's password: `.
  const SshPasswordPrompt(super.text, {super.isVerified, super.withdrawn});
}

/// Anything else: mostly the server asking in its own words
/// (keyboard-interactive), such as `Verification code: ` for 2FA, or
/// `(alice@ssh.example.com) Password: ` for a password it checks itself, but
/// also ssh's own `Enter PIN for ED25519-SK key …: ` for a hardware key.
final class SshCodePrompt extends SshPrompt {
  /// The server's [text].
  const SshCodePrompt(super.text, {super.isVerified, super.withdrawn});
}

/// Answers an [SshPrompt]: the text to send, or null to cancel the login. An
/// answer can't hold a line break; one that does cancels too.
typedef SshPromptHandler = Future<String?> Function(SshPrompt prompt);

final _passphrase = RegExp(r"^Enter passphrase for key '(.*)': ?$");

// "Enter alice@host's old password: " and the like come when the server asks
// for a new password. A local account name, ssh's default user, may hold a
// space.
final _password = RegExp(
  r"^(Enter |Retype )?.+@[^@\s]+'s (old |new )?password: ?$",
);

/// Whether [text] is ssh's yes/no question about an unknown or changed host
/// key. A server's own questions start with `(user@host)`, so it can't pose
/// as one.
bool isHostKeyQuestion(String text) =>
    !text.startsWith('(') &&
    (text.contains('Are you sure you want to continue connecting (yes/no') ||
        text.startsWith("Please type 'yes', 'no' or the fingerprint"));

/// [text], from ssh, as the kind of prompt its wording says; see
/// [SshPrompt.isVerified].
SshPrompt classifyPrompt(
  String text, {
  bool isVerified = true,
  Future<void>? withdrawn,
}) {
  // A server's question, marked so since OpenSSH 8.5, whatever it says after.
  if (text.startsWith('(')) {
    return SshCodePrompt(text, isVerified: isVerified, withdrawn: withdrawn);
  }
  if (_passphrase.firstMatch(text) case final match?) {
    return SshPassphrasePrompt(
      text,
      keyPath: match[1]!,
      isVerified: isVerified,
      withdrawn: withdrawn,
    );
  }
  if (_password.hasMatch(text)) {
    return SshPasswordPrompt(
      text,
      isVerified: isVerified,
      withdrawn: withdrawn,
    );
  }
  return SshCodePrompt(text, isVerified: isVerified, withdrawn: withdrawn);
}
