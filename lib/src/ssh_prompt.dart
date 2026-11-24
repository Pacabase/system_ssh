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
  const SshPrompt(this.text);

  /// The prompt as ssh shows it, such as `alice@ssh.example.com's password: `.
  /// For an [SshCodePrompt] these are the server's own words, so show them as
  /// plain text, never as markup.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SshPrompt &&
      other.runtimeType == runtimeType &&
      other.text == text;

  @override
  int get hashCode => Object.hash(runtimeType, text);

  // Spelled out, since an obfuscated build renames runtimeType.
  @override
  String toString() => '${switch (this) {
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
  const SshPassphrasePrompt(super.text, {required this.keyPath});

  /// The key file, as ssh names it, cut short past 100 characters.
  final String keyPath;
}

/// ssh asks for the user's password on a server, or a `ProxyJump` host on
/// the way.
final class SshPasswordPrompt extends SshPrompt {
  /// ssh's [text], such as `alice@ssh.example.com's password: `.
  const SshPasswordPrompt(super.text);
}

/// Anything else: mostly the server asking in its own words
/// (keyboard-interactive), such as `Verification code: ` for 2FA, or
/// `(alice@ssh.example.com) Password: ` for a password it checks itself, but
/// also ssh's own `Enter PIN for ED25519-SK key …: ` for a hardware key.
final class SshCodePrompt extends SshPrompt {
  /// The server's [text].
  const SshCodePrompt(super.text);
}

/// Answers an [SshPrompt]: the text to send, or null to cancel the login. An
/// answer can't hold a line break; one that does cancels too.
typedef SshPromptHandler = Future<String?> Function(SshPrompt prompt);

final _passphrase = RegExp(r"^Enter passphrase for key '(.*)': ?$");

// "Enter alice@host's old password: " and the like come when the server asks
// for a new password. A local account name, ssh's default user, may hold a
// space.
final _password =
    RegExp(r"^(Enter |Retype )?.+@[^@\s]+'s (old |new )?password: ?$");

/// Whether [text] is ssh's yes/no question about an unknown or changed host
/// key. A server's own questions start with `(user@host)`, so it can't pose
/// as one.
bool isHostKeyQuestion(String text) =>
    !text.startsWith('(') &&
    (text.contains('Are you sure you want to continue connecting (yes/no') ||
        text.startsWith("Please type 'yes', 'no' or the fingerprint"));

/// [text], from ssh, as the kind of prompt its wording says.
SshPrompt classifyPrompt(String text) {
  if (_passphrase.firstMatch(text) case final match?) {
    return SshPassphrasePrompt(text, keyPath: match[1]!);
  }
  if (_password.hasMatch(text)) return SshPasswordPrompt(text);
  return SshCodePrompt(text);
}
