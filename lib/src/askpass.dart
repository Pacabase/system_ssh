import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'askpass_locator.dart';
import 'exceptions.dart';
import 'logger.dart';
import 'ssh_log.dart';
import 'ssh_prompt.dart';

/// The helper ssh runs as `SSH_ASKPASS` for each prompt, which hands the
/// prompt to an [SshPromptHandler] and the answer back to ssh. The answer
/// never goes through an argument, the environment or a file: a FIFO in a
/// directory only this user can open on POSIX, and a loopback socket that
/// asks for a token on Windows. Once a prompt is cancelled, the rest are too,
/// without asking, and ssh is stopped before it would send an empty password.
final class AskPass {
  AskPass._(this._directory, this._onPrompt, this._verified);

  /// Sets up the helper for [onPrompt] in a directory of its own, in the
  /// first of [bases] (by default the temp directory, then
  /// `XDG_RUNTIME_DIR`, then `~/.cache`) where it can run: a hardened `/tmp`
  /// may forbid running programs. On Windows, ssh runs the helper program
  /// the build hook bundled. Each prompt's
  /// [SshPrompt.isVerified] is [verified].
  static Future<AskPass> start(
    SshPromptHandler onPrompt, {
    List<String>? bases,
    bool verified = true,
  }) async {
    final failures = <String>[];
    for (final base in bases ?? _bases()) {
      final Directory directory;
      try {
        directory = Directory(base).createTempSync('ssh_askpass');
      } on FileSystemException catch (exception) {
        failures.add('$base: ${exception.message}');
        continue;
      }

      final askPass = AskPass._(directory, onPrompt, verified);
      try {
        await (Platform.isWindows
            ? askPass._startWindows()
            : askPass._startPosix());
        return askPass;
      } on _NotRunnable catch (exception) {
        failures.add('$base: ${exception.reason}');
        await askPass.close();
      } catch (exception) {
        await askPass.close();
        rethrow;
      }
    }
    throw SshConfigException(
      'no folder lets the password prompt run: ${failures.join('; ')}',
    );
  }

  static List<String> _bases() {
    final environment = Platform.environment;
    return [
      Directory.systemTemp.path,
      if (!Platform.isWindows) ...[
        if (environment['XDG_RUNTIME_DIR'] case final runtime?
            when runtime.isNotEmpty)
          runtime,
        if (environment['HOME'] case final home? when home.isNotEmpty)
          if (Directory('$home/.cache').existsSync()) '$home/.cache',
      ],
    ];
  }

  final Directory _directory;
  final SshPromptHandler _onPrompt;
  final bool _verified;
  late final String _helper;
  Timer? _poll;
  ServerSocket? _server;
  late final String _token;
  final _connections = <Socket>{};
  var _isClosed = false;

  // One prompt at a time across every tunnel, so an app never shows two
  // dialogs at once. A closed helper's prompt stops holding up the rest.
  static var _queue = Future<void>.value();
  final _closed = Completer<void>();

  /// Completes when ssh must be stopped: it would send an empty password, or
  /// an empty answer to the server's question, for a cancelled prompt.
  Future<void> get stop => _stop.future;
  final _stop = Completer<void>();

  /// Whether [_onPrompt] answered null to any prompt.
  bool get wasCancelled => _wasCancelled;
  var _wasCancelled = false;

  /// What [_onPrompt] threw, if it did; the login is cancelled then too.
  (Object, StackTrace)? get error => _error;
  (Object, StackTrace)? _error;

  /// Whether a helper reached the app on Windows, where something may block
  /// it from running.
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
    if (!_isLoginFailure(exception)) return exception;
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
    if (_isLoginFailure(exception)) {
      if (_error case (final error, final errorStackTrace)) {
        Error.throwWithStackTrace(error, errorStackTrace);
      }
      final asked = exception.log.any(
        (line) => line.contains('read_passphrase: requested to askpass'),
      );
      if (Platform.isWindows && asked && !_helperConnected) {
        logger.warning(
          'ssh asked, but its password helper never reached the app; '
          'something on this computer may block it',
        );
      }
    }
    Error.throwWithStackTrace(failure(exception), stackTrace);
  }

  /// A refused login, or ssh stopped because of a cancelled prompt.
  bool _isLoginFailure(SshException exception) =>
      exception is SshLoginRefusedException ||
      (_stop.isCompleted && exception is SshTunnelAbortedException);

  /// Stops answering, and has any helper still waiting give up.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _closed.complete();
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
    final previous = _queue;
    final answer = previous.then((_) async {
      if (_isClosed) return null;
      // An unknown ProxyJump host's key, which the jump's own ssh asks
      // about; host keys are for trustHostKey to settle.
      if (isHostKeyQuestion(text)) {
        logger.info('Declined a host key question: $text');
        return null;
      }
      final prompt = classifyPrompt(text, isVerified: _verified);
      if (_wasCancelled || _error != null) return _refuse(prompt);
      logger.info('ssh asks: $prompt');
      try {
        final answer = await _onPrompt(prompt);
        if (answer == null) {
          _wasCancelled = true;
          return _refuse(prompt);
        }
        if (answer.contains(RegExp('[\r\n]'))) {
          logger.warning('An answer with a line break was cancelled');
          _wasCancelled = true;
          return _refuse(prompt);
        }
        // ssh reads at most 1023 bytes of an answer and drops the rest.
        if (utf8.encode(answer).length > 1023) {
          logger.warning('An answer longer than ssh reads was cancelled');
          _wasCancelled = true;
          return _refuse(prompt);
        }
        return answer;
      } catch (exception, stackTrace) {
        logger.warning('onPrompt threw', exception, stackTrace);
        _error ??= (exception, stackTrace);
        return _refuse(prompt);
      }
    });
    // A closed helper stops holding the line, but not before the prompt
    // ahead of it is answered.
    _queue = previous.then(
      (_) => Future.any([answer.then((_) {}), _closed.future]),
    );
    return answer;
  }

  /// No answer. ssh skips a key whose passphrase isn't given, but sends a
  /// password or a server's question empty, which the server counts as a
  /// failed login, so for those ssh is stopped instead.
  String? _refuse(SshPrompt prompt) {
    if (prompt is! SshPassphrasePrompt && !_stop.isCompleted) _stop.complete();
    return null;
  }

  Future<void> _startPosix() async {
    _helper = '${_directory.path}/askpass';
    final quoted = "'${_directory.path.replaceAll("'", r"'\''")}'";
    File(_helper).writeAsStringSync(_posixScript.replaceAll('@DIR@', quoted));
    // createTemp leaves the directory to the umask on Linux, so 755 there.
    final chmod = await Process.run('chmod', ['700', _directory.path, _helper]);
    if (chmod.exitCode != 0) {
      throw SshFailedException(
        'could not set up the password prompt: ${chmod.stderr}',
      );
    }
    // A notice, which the helper answers at once, shows it can run here.
    try {
      final probe = await Process.run(
        _helper,
        const [],
        environment: const {'SSH_ASKPASS_PROMPT': 'none'},
      );
      if (probe.exitCode != 0) throw _NotRunnable('exit ${probe.exitCode}');
    } on ProcessException catch (exception) {
      throw _NotRunnable(exception.message);
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
      // A helper left unanswered goes with ssh, which is being stopped.
      unawaited(
        _answer(text).then((answer) {
          if (!_stop.isCompleted) _reply(id, answer);
        }),
      );
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
      // The helper's watchdog can remove the FIFO the instant before the
      // open, which then creates a plain file instead; it mustn't stay.
      if (FileSystemEntity.typeSync(fifo, followLinks: false) ==
          FileSystemEntityType.file) {
        File(fifo).deleteSync();
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

    // withPrompts checks first that it's there and runs.
    _helper = bundledWindowsHelper!;
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
      // Holding the connection keeps the helper from answering until ssh,
      // which is being stopped, and the helper with it, are gone.
      if (_stop.isCompleted) return await _closed.future;
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

// ssh runs it with the prompt in $1, and reads the answer from its stdout.
// SSH_ASKPASS_PROMPT is `none` for a notice, such as to touch a hardware
// key, which ssh doesn't wait on, and `confirm` for a yes/no question, which
// a tunnel never needs. The answer comes through a FIFO the script holds open
// itself, so the app's write never waits, and stays in printf, a builtin, so
// it never appears in a process's arguments. The background loop ends once
// ssh is gone or the FIFO is, by the script or by the app closing, and then
// answers `n` through the FIFO it shares, so a script still waiting gives
// up. It leaves stdout alone, since ssh reads it to the end. The script
// ignores TERM: stopping ssh stops its children first, and ssh, seeing the
// script fail, would send an empty password before its own TERM came. ssh leaves its
// end of that stdout pipe open in the script too, so the script closes what
// it inherited first, and the loop never waits on the script itself.
const _posixScript = r'''#!/bin/sh
d=@DIR@
case "${SSH_ASKPASS_PROMPT:-}" in none) exit 0 ;; confirm) exit 1 ;; esac
[ -d "$d" ] || exit 1
trap '' TERM
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
    result = await Process.run(executable, [
      '-V',
    ], environment: environment).timeout(const Duration(seconds: 5));
  } on ProcessException {
    return null;
  } on TimeoutException {
    return null;
  }
  final match = RegExp(
    r'OpenSSH_(?:for_Windows_)?(\d+)\.(\d+)',
  ).firstMatch('${result.stderr}${result.stdout}');
  if (match == null) return null;
  return (int.parse(match[1]!), int.parse(match[2]!));
}

/// Whether [version] is older than [major].[minor].
bool _olderThan((int, int)? version, int major, int minor) => switch (version) {
  (final versionMajor, final versionMinor) =>
    versionMajor < major || (versionMajor == major && versionMinor < minor),
  null => false,
};

/// Why ssh can't ask on this computer, or null when it can: on Windows,
/// the helper program must be with the app, and Windows must let it run.
Future<String?> _whyNoPrompts() async {
  if (!Platform.isWindows) return null;
  final helper = bundledWindowsHelper;
  if (helper == null) {
    return "system_ssh_askpass.exe isn't with the app, so ssh can't ask";
  }
  return _windowsHelperRefusal ??= _tryWindowsHelper(helper);
}

Future<String?>? _windowsHelperRefusal;

// Antivirus or an AppLocker policy may block an unsigned program; ssh would
// then fail every prompt without saying why.
Future<String?> _tryWindowsHelper(String helper) async {
  try {
    final result = await Process.run(
      helper,
      const [],
      environment: {'SSH_ASKPASS_PROMPT': 'none'},
    ).timeout(const Duration(seconds: 10));
    if (result.exitCode == 0) return null;
    return "Windows wouldn't run $helper (exit code ${result.exitCode}), so "
        "ssh can't ask";
  } on ProcessException catch (exception) {
    return "Windows wouldn't run $helper (${exception.message}), so ssh "
        "can't ask";
  } on TimeoutException {
    return "$helper didn't answer in time, so ssh can't ask";
  }
}

/// Runs [open] with the environment and options ssh needs to ask
/// [onPrompt], or as before when [onPrompt] is null or ssh can't ask here.
/// A login that fails after a cancelled prompt throws an
/// [SshLoginCancelledException], or what [onPrompt] threw.
///
/// When ssh can't ask, [onLog] gets an [SshPromptsOff], and a refused login
/// says why in its message.
Future<T> withPrompts<T>(
  SshPromptHandler? onPrompt, {
  required String executable,
  required Map<String, String> environment,
  required Future<T> Function(SshPrompts prompts) open,
  void Function(SshLog log)? onLog,
}) async {
  if (onPrompt == null) return open(SshPrompts.none(environment));
  if (await _whyNoPrompts() case final why?) {
    final off = SshPromptsOff(why);
    logger.warning(off.line);
    reportTo(onLog, off);
    try {
      return await open(SshPrompts.none(environment));
    } on SshLoginRefusedException catch (exception, stackTrace) {
      Error.throwWithStackTrace(
        SshLoginRefusedException(
          '${exception.message} (not asking for passwords: $why)',
          log: exception.log,
          exitCode: exception.exitCode,
        ),
        stackTrace,
      );
    }
  }

  final version = await sshVersion(executable, environment: environment);
  final askPass = await AskPass.start(
    onPrompt,
    // An ssh whose version can't be read may be old.
    verified: version != null && !_olderThan(version, 8, 5),
  );
  try {
    return await open(
      SshPrompts._(
        {
          ...environment,
          ...askPass.environment,
          // Before 8.4, which added SSH_ASKPASS_REQUIRE, ssh uses
          // SSH_ASKPASS only with a DISPLAY set, and only when it has no
          // terminal: run from one, it asks there instead.
          if (_olderThan(version, 8, 4) &&
              !environment.containsKey('DISPLAY') &&
              !Platform.environment.containsKey('DISPLAY'))
            'DISPLAY': ':0',
        },
        enabled: true,
        stop: askPass.stop,
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
  SshPrompts._(this.environment, {required this.enabled, this.stop});

  /// No prompts: ssh runs in [environment] with `BatchMode=yes`.
  SshPrompts.none(this.environment) : enabled = false, stop = null;

  final Map<String, String> environment;

  /// For `sshCommand`'s `prompts`.
  final bool enabled;

  /// Completes when ssh must be stopped; see [AskPass.stop].
  final Future<void>? stop;

  /// What stops ssh while it connects: [abortTrigger] or [stop]. A trigger
  /// that fails never aborts, as before.
  Future<void>? stopOr(Future<void>? abortTrigger) {
    final stop = this.stop;
    if (stop == null) return abortTrigger;
    if (abortTrigger == null) return stop;
    return Future.any([
      abortTrigger.then(
        (_) {},
        onError: (Object _) => Completer<void>().future,
      ),
      stop,
    ]);
  }
}

final class _NotRunnable implements Exception {
  const _NotRunnable(this.reason);

  final String reason;
}
