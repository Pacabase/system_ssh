import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'exceptions.dart';
import 'logger.dart';
import 'ssh_prompt.dart';

/// The helper ssh runs as `SSH_ASKPASS` for each prompt, which hands the
/// prompt to an [SshPromptHandler] and the answer back to ssh. The answer
/// never goes through an argument, the environment or a file: a FIFO in a
/// directory only this user can open on POSIX, and a loopback socket that
/// asks for a token on Windows. Once a prompt is cancelled, the rest are too,
/// without asking.
final class AskPass {
  AskPass._(this._directory, this._onPrompt);

  /// Sets up the helper for [onPrompt] in a directory of its own.
  static Future<AskPass> start(SshPromptHandler onPrompt) async {
    final Directory directory;
    try {
      directory = Directory.systemTemp.createTempSync('ssh_askpass');
    } on FileSystemException catch (exception) {
      throw SshFailedException(
        'could not make a directory for the password prompt: '
        '${exception.message}',
      );
    }

    final askPass = AskPass._(directory, onPrompt);
    try {
      await (Platform.isWindows
          ? askPass._startWindows()
          : askPass._startPosix());
    } catch (exception) {
      await askPass.close();
      rethrow;
    }
    return askPass;
  }

  final Directory _directory;
  final SshPromptHandler _onPrompt;
  late final String _helper;
  Timer? _poll;
  ServerSocket? _server;
  late final String _token;
  final _connections = <Socket>{};
  var _isClosed = false;

  // One prompt at a time, so an app never shows two dialogs at once.
  var _queue = Future<void>.value();

  /// Whether [_onPrompt] answered null to any prompt.
  bool get wasCancelled => _wasCancelled;
  var _wasCancelled = false;

  /// What [_onPrompt] threw, if it did; the login is cancelled then too.
  (Object, StackTrace)? get error => _error;
  (Object, StackTrace)? _error;

  /// Whether a helper reached the app on Windows, where PowerShell may be
  /// locked down.
  var _helperConnected = false;

  /// What ssh needs in its environment to ask through the helper.
  Map<String, String> get environment => {
        'SSH_ASKPASS': _helper,
        // Without it, ssh asks on a terminal when it has one, and before
        // OpenSSH 8.4 only uses SSH_ASKPASS with a DISPLAY set.
        'SSH_ASKPASS_REQUIRE': 'force',
        // The environment of another user's process is out of reach, unlike
        // a file in a %TEMP% that may be shared.
        if (Platform.isWindows) ...{
          'SYSTEM_SSH_ASKPASS_PORT': '${_server!.port}',
          'SYSTEM_SSH_ASKPASS_TOKEN': _token,
        },
      };

  /// [exception], or what the answers say happened instead: for a refused
  /// login, the error [_onPrompt] threw, or an [SshLoginCancelledException].
  /// Any other failure, such as a host key or a taken port, stays itself.
  Object failure(SshException exception) {
    if (exception is! SshLoginRefusedException) return exception;
    if (_error case (final error, _)) return error;
    if (_wasCancelled) {
      return SshLoginCancelledException(
        log: exception.log,
        exitCode: exception.exitCode,
      );
    }
    return exception;
  }

  /// Rethrows [exception] as [failure] says.
  Never rethrowAs(SshException exception, StackTrace stackTrace) {
    if (exception is SshLoginRefusedException) {
      if (_error case (final error, final errorStackTrace)) {
        Error.throwWithStackTrace(error, errorStackTrace);
      }
      final asked = exception.log.any(
        (line) => line.contains('read_passphrase: requested to askpass'),
      );
      if (Platform.isWindows && asked && !_helperConnected) {
        logger.warning(
          'ssh never reached the password prompt; PowerShell may be blocked '
          'on this computer',
        );
      }
    }
    Error.throwWithStackTrace(failure(exception), stackTrace);
  }

  /// Stops answering, and has any helper still waiting give up.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _poll?.cancel();
    await _server?.close();
    // Closing the server leaves the helpers it accepted waiting; this ends
    // their read, and they give up.
    for (final socket in [..._connections]) {
      socket.destroy();
    }
    if (!Platform.isWindows) _cancelWaitingHelpers();
    try {
      _directory.deleteSync(recursive: true);
    } on FileSystemException {
      // Left to the OS's temp cleanup.
    }
  }

  /// The answer to [text], or null to cancel. Never throws.
  Future<String?> _answer(String text) {
    final answer = _queue.then((_) async {
      if (_isClosed || _wasCancelled || _error != null) return null;
      final prompt = classifyPrompt(text);
      logger.info('ssh asks: $prompt');
      try {
        final answer = await _onPrompt(prompt);
        if (answer == null) {
          _wasCancelled = true;
        } else if (answer.contains(RegExp('[\r\n]'))) {
          logger.warning('An answer with a line break was cancelled');
          _wasCancelled = true;
          return null;
        }
        return answer;
      } catch (error, stackTrace) {
        _error ??= (error, stackTrace);
        return null;
      }
    });
    _queue = answer.then((_) {});
    return answer;
  }

  Future<void> _startPosix() async {
    _helper = '${_directory.path}/askpass';
    final quoted = "'${_directory.path.replaceAll("'", r"'\''")}'";
    File(_helper).writeAsStringSync(_posixScript.replaceAll('@DIR@', quoted));
    // createTemp already made the directory 0700.
    final chmod = await Process.run('chmod', ['700', _helper]);
    if (chmod.exitCode != 0) {
      throw SshFailedException(
        'could not set up the password prompt: ${chmod.stderr}',
      );
    }
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) => _scan());
  }

  void _scan() {
    if (_isClosed) return;
    final List<FileSystemEntity> entries;
    try {
      entries = _directory.listSync();
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      final name = entry.uri.pathSegments.last;
      if (!name.endsWith('.prompt')) continue;

      final id = name.substring(0, name.length - '.prompt'.length);
      final String text;
      final file = File(entry.path);
      try {
        // A key path or a server's words needn't be UTF-8.
        text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
        file.deleteSync();
      } on FileSystemException {
        continue;
      }
      unawaited(_answer(text).then((answer) => _reply(id, answer)));
    }
  }

  void _reply(String id, String? answer) {
    final fifo = '${_directory.path}/$id.answer';
    // Never create a file holding the answer: only a FIFO the helper made.
    if (FileSystemEntity.typeSync(fifo, followLinks: false) !=
        FileSystemEntityType.pipe) {
      return;
    }
    // Opened for reading and writing, which doesn't wait for a reader. The
    // helper holds the FIFO open itself, so the line waits for it there, and
    // removes it only once it has read the line, so it can't vanish between
    // the check and the open.
    try {
      final file = File(fifo).openSync(mode: FileMode.write);
      try {
        file.writeStringSync(answer == null ? 'n\n' : 'y$answer\n');
      } finally {
        file.closeSync();
      }
    } on FileSystemException catch (exception) {
      logger.warning('Could not answer ssh: ${exception.message}');
    }
  }

  void _cancelWaitingHelpers() {
    final List<FileSystemEntity> entries;
    try {
      entries = _directory.listSync();
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      final name = entry.uri.pathSegments.last;
      if (name.endsWith('.answer')) {
        _reply(name.substring(0, name.length - '.answer'.length), null);
      }
    }
  }

  Future<void> _startWindows() async {
    _token = _randomToken();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_serveWindows);

    _helper = '${_directory.path}\\askpass.cmd';
    File(_helper).writeAsStringSync(_windowsHelper);
  }

  Future<void> _serveWindows(Socket socket) async {
    socket.done.ignore();
    if (_isClosed) return socket.destroy();
    _connections.add(socket);
    try {
      // Any user on this computer can connect, so it reads only as much as a
      // helper sends: the token, then a prompt.
      final lines = StreamIterator(
        _boundedLines(socket, limit: _maxPromptBytes),
      );
      Future<List<int>?> next() async =>
          await lines.moveNext() ? lines.current : null;

      final presented = await next().timeout(const Duration(seconds: 5));
      if (presented == null || !_sameToken(presented, ascii.encode(_token))) {
        logger.warning('A connection to the password prompt had no token');
        return;
      }
      _helperConnected = true;
      final encoded = await next().timeout(const Duration(seconds: 5));
      if (encoded == null) return;
      final text = utf8.decode(
        base64.decode(ascii.decode(encoded)),
        allowMalformed: true,
      );

      final answer = await _answer(text);
      socket.write(answer == null ? 'n\n' : 'y$answer\n');
      await socket.flush();
      await lines.cancel();
    } catch (exception) {
      if (!_isClosed) logger.warning('The password prompt failed: $exception');
    } finally {
      _connections.remove(socket);
      socket.destroy();
    }
  }
}

/// The most a helper sends: a token, and a prompt as base64.
const _maxPromptBytes = 16 * 1024;

/// [socket]'s lines, as bytes without the newline, failing once it has sent
/// more than [limit] bytes.
Stream<List<int>> _boundedLines(Socket socket, {required int limit}) async* {
  final buffer = <int>[];
  var received = 0;
  await for (final chunk in socket) {
    received += chunk.length;
    if (received > limit) throw const FormatException('too much input');
    for (final byte in chunk) {
      if (byte != 0x0a) {
        buffer.add(byte);
        continue;
      }
      yield [...buffer];
      buffer.clear();
    }
  }
}

String _randomToken() {
  final random = Random.secure();
  return [
    for (var i = 0; i < 32; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

bool _sameToken(List<int> presented, List<int> token) {
  if (presented.length != token.length) return false;
  var difference = 0;
  for (var i = 0; i < token.length; i++) {
    difference |= presented[i] ^ token[i];
  }
  return difference == 0;
}

List<int> _utf16le(String text) => [
      for (final unit in text.codeUnits) ...[unit & 0xff, unit >> 8],
    ];

final _windowsHelper = _windowsCommand
    .replaceAll('@SCRIPT@', base64.encode(_utf16le(_windowsScript)))
    .replaceAll('\n', '\r\n');

// ssh runs it with the prompt in $1, and reads the answer from its stdout.
// SSH_ASKPASS_PROMPT is `none` for a notice, such as to touch a hardware
// key, which ssh doesn't wait on, and `confirm` for a yes/no question, which
// a tunnel never needs. The answer comes through a FIFO the script holds open
// itself, so the app's write never waits, and stays in printf, a builtin, so
// it never appears in a process's arguments. The background loop ends once
// ssh is gone or the FIFO is, by the script or by the app closing, and then
// answers `n` through the FIFO it shares, so a script still waiting gives
// up. It leaves stdout alone, since ssh reads it to the end. ssh leaves its
// end of that stdout pipe open in the script too, so the script closes what
// it inherited first, and the loop never waits on the script itself.
const _posixScript = r'''#!/bin/sh
d=@DIR@
case "${SSH_ASKPASS_PROMPT:-}" in none) exit 0 ;; confirm) exit 1 ;; esac
[ -d "$d" ] || exit 1
exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
umask 077
r="$d/$$"
mkfifo "$r.answer" || exit 1
exec 3<>"$r.answer"
( while kill -0 "$PPID" 2>/dev/null && [ -p "$r.answer" ]; do sleep 1; done
  echo n >&3 ) </dev/null >/dev/null 2>&1 &
printf '%s' "$1" > "$r.tmp" && mv "$r.tmp" "$r.prompt" || exit 1
IFS= read -r a <&3
exec 3<&-
rm -f "$r.answer"
case $a in
  y*) printf '%s\n' "${a#y}" ;;
  *) exit 1 ;;
esac
''';

// cmd.exe runs it as `cmd /c ""askpass.cmd" "<prompt>""`, which expands
// `%NAME%` and, with delayed expansion on, `!NAME!` in the prompt before it
// reads quotes, and a `"` there would end the quoting. So on Windows only
// ssh's own prompts come, and only when the user, host and key files in them
// hold none of those characters; see canPrompt. Inside the quotes, `&` and
// the like are plain text. PowerShell's stderr goes nowhere: it shares ssh's,
// and its first start there writes a progress record.
const _windowsCommand = r'''@echo off
setlocal DisableDelayedExpansion
if "%SSH_ASKPASS_PROMPT%"=="none" exit /b 0
if "%SSH_ASKPASS_PROMPT%"=="confirm" exit /b 1
set "SYSTEM_SSH_PROMPT=%~1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand @SCRIPT@ 2>nul
exit /b %ERRORLEVEL%
''';

// An encoded command, which no execution policy blocks.
const _windowsScript = r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', [int]$env:SYSTEM_SSH_ASKPASS_PORT)
  $stream = $client.GetStream()
  $writer = New-Object System.IO.StreamWriter($stream, $utf8)
  $writer.NewLine = "`n"
  $reader = New-Object System.IO.StreamReader($stream, $utf8)
  $writer.WriteLine($env:SYSTEM_SSH_ASKPASS_TOKEN)
  $writer.WriteLine([Convert]::ToBase64String($utf8.GetBytes($env:SYSTEM_SSH_PROMPT)))
  $writer.Flush()
  $answer = $reader.ReadLine()
  $client.Close()
  if ($answer -ne $null -and $answer.StartsWith('y')) {
    $bytes = $utf8.GetBytes($answer.Substring(1) + "`n")
    $out = [Console]::OpenStandardOutput()
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
    exit 0
  }
} catch {}
exit 1
''';

/// The OpenSSH version [executable] reports, such as `(9, 5)`, or null when
/// its `ssh -V` says no version, kept per executable.
Future<(int, int)?> sshVersion(
  String executable, {
  Map<String, String> environment = const {},
}) async {
  final known = _versions[executable];
  if (known != null) return known;
  final version = await _readVersion(executable, environment);
  if (version != null) _versions[executable] = version;
  return version;
}

final _versions = <String, (int, int)>{};

Future<(int, int)?> _readVersion(
  String executable,
  Map<String, String> environment,
) async {
  final ProcessResult result;
  try {
    result = await Process.run(executable, ['-V'], environment: environment)
        .timeout(const Duration(seconds: 5));
  } on ProcessException {
    return null;
  } on TimeoutException {
    return null;
  }
  final match = RegExp(r'OpenSSH_(?:for_Windows_)?(\d+)\.(\d+)')
      .firstMatch('${result.stderr}${result.stdout}');
  if (match == null) return null;
  return (int.parse(match[1]!), int.parse(match[2]!));
}

/// Throws an [SshConfigException] when [executable] is an OpenSSH older than
/// 8.4, whose `SSH_ASKPASS` can't be made to ask without a terminal.
Future<void> checkPromptSupport(
  String executable, {
  Map<String, String> environment = const {},
}) async {
  final version = await sshVersion(executable, environment: environment);
  if (version case (final major, final minor)
      when major < 8 || (major == 8 && minor < 4)) {
    throw SshConfigException(
      'OpenSSH $major.$minor is too old to ask for a password or passphrase; '
      'it needs 8.4 or newer',
    );
  }
}

/// Whether ssh may ask through `onPrompt` with [config], what `ssh -G` said.
///
/// On Windows, ssh runs the helper through cmd.exe, which would read a
/// server's own words as commands, so there a login asks only ssh's own
/// prompts: keyboard-interactive is turned off, and nothing asks when a
/// `ProxyJump` or `ProxyCommand` runs another ssh, which wouldn't get that
/// option, when the config couldn't be read, or when the user, host or a key
/// file ssh would name in a prompt holds a character cmd.exe reads.
bool canPrompt(Map<String, String> config, {bool? onWindows}) =>
    _whyNoPrompts(config, onWindows: onWindows ?? Platform.isWindows) == null;

String? _whyNoPrompts(Map<String, String> config, {required bool onWindows}) {
  if (!onWindows) return null;
  if (config.isEmpty) return "ssh -G couldn't read the config";
  for (final option in ['proxyjump', 'proxycommand']) {
    if (config.containsKey(option)) return 'the config sets a $option';
  }
  for (final option in _inPrompts) {
    if (config[option]?.contains(_readByCmd) ?? false) {
      return 'its $option holds one of " % ! ^ & | < >';
    }
  }
  return null;
}

const _inPrompts = ['user', 'hostname', 'identityfile', 'certificatefile'];
final _readByCmd = RegExp(r'["%!^&|<>]');

/// Runs [open] with the environment and options ssh needs to ask
/// [onPrompt], or as before when [onPrompt] is null or [canPrompt] says no.
/// A login that fails after a cancelled prompt throws an
/// [SshLoginCancelledException], or what [onPrompt] threw.
Future<T> withPrompts<T>(
  SshPromptHandler? onPrompt, {
  required String executable,
  required Map<String, String> config,
  required Map<String, String> environment,
  required Future<T> Function(SshPrompts prompts) open,
}) async {
  if (onPrompt == null) return open(SshPrompts.none(environment));
  if (_whyNoPrompts(config, onWindows: Platform.isWindows) case final why?) {
    logger.warning(
      "Not asking for passwords: Windows' ssh can't ask safely when $why",
    );
    return open(SshPrompts.none(environment));
  }
  await checkPromptSupport(executable, environment: environment);

  final askPass = await AskPass.start(onPrompt);
  try {
    return await open(
      SshPrompts._(
        {...environment, ...askPass.environment},
        enabled: true,
        ownOnly: Platform.isWindows,
      ),
    );
  } on SshException catch (exception, stackTrace) {
    askPass.rethrowAs(exception, stackTrace);
  } finally {
    await askPass.close();
  }
}

/// How one ssh asks for passwords: the [environment] to run it in, and
/// whether its command turns prompts on.
final class SshPrompts {
  SshPrompts._(this.environment, {required this.enabled, this.ownOnly = false});

  /// No prompts: ssh runs in [environment] with `BatchMode=yes`.
  SshPrompts.none(this.environment)
      : enabled = false,
        ownOnly = false;

  final Map<String, String> environment;

  /// For `sshCommand`'s `prompts`.
  final bool enabled;

  /// For `sshCommand`'s `ownPromptsOnly`.
  final bool ownOnly;
}
