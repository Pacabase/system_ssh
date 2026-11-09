import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'fake_ssh_main.dart' show AttemptMode;
import 'fakes.dart';

export 'fake_ssh_main.dart' show AttemptMode;

/// An executable at [path] that plays ssh, chosen through the `executable:`
/// parameter. It answers `-G` per [answerConfig], [hangOnConfig] or
/// [failConfig], and plays each tunnel attempt per [attemptModes].
final class FakeSsh {
  FakeSsh._(this._directory);

  final Directory _directory;

  /// Copies the fake into a temp dir that goes, with any process the fake
  /// left running, when the test ends.
  static Future<FakeSsh> create() async {
    final directory = Directory.systemTemp.createTempSync('fake_ssh');
    final fake = FakeSsh._(directory);
    addTearDown(fake._dispose);

    File(await fakeSshExecutable).copySync(fake.path);
    return fake;
  }

  String get directory => _directory.path;

  /// The fake's executable.
  String get path =>
      '${_directory.path}${Platform.pathSeparator}ssh${Platform.isWindows ? '.exe' : ''}';

  /// Has `ssh -G` print [lines].
  void answerConfig(List<String> lines) =>
      _file('config').writeAsStringSync(lines.map((line) => '$line\n').join());

  /// Has `ssh -G` hang.
  void hangOnConfig() => _file('config_mode').writeAsStringSync('hang');

  /// Has `ssh -G` start a child, as a `Match exec` does, then hang.
  void hangOnConfigWithChild() =>
      _file('config_mode').writeAsStringSync('hang-with-child');

  /// Has `ssh -G` fail.
  void failConfig() => _file('config_mode').writeAsStringSync('fail');

  /// One mode per attempt; attempts past the end repeat the last.
  void attemptModes(List<AttemptMode> modes) => _file('modes')
      .writeAsStringSync(modes.map((mode) => mode.name).join('\n'));

  /// Answers each `ssh -O` command in turn: `ok`, `fail`, or `silent-fail`
  /// (fails but exits 0); commands past the end repeat the last.
  void muxModes(List<String> modes) =>
      _file('mux_modes').writeAsStringSync(modes.join('\n'));

  /// Has a master that is up write [line] to its stderr.
  void masterSays(String line) =>
      _file('master_say').writeAsStringSync('$line\n', mode: FileMode.append);

  /// The arguments of each `ssh -O` command, in order.
  List<List<String>> get muxCommands => [
        for (var command = 1; _file('mux.$command').existsSync(); command++)
          _file('mux.$command').readAsLinesSync(),
      ];

  /// What `ssh -G` was run with, or null if it wasn't.
  List<String>? get configArguments {
    final file = _file('config_argv');
    return file.existsSync() ? file.readAsLinesSync() : null;
  }

  /// The environment `ssh -G` ran with, or null if it didn't run.
  Map<String, String>? get configEnvironment => _environment('config_env');

  List<Map<String, String>> get attemptEnvironments => [
        for (var attempt = 1; _file('env.$attempt').existsSync(); attempt++)
          _environment('env.$attempt')!,
      ];

  /// The pid of `ssh -G`, once it has started.
  Future<int> get configPid => eventually(() => _pid('config_pid'));

  /// The pid of the child [hangOnConfigWithChild] makes `ssh -G` start.
  Future<int> get configChildPid => eventually(() {
        final file = _file('config_children');
        return file.existsSync()
            ? file.readAsLinesSync().map(int.tryParse).elementAtOrNull(1)
            : null;
      });

  /// The arguments of each tunnel attempt, in order.
  List<List<String>> get attempts => [
        for (var attempt = 1; _file('argv.$attempt').existsSync(); attempt++)
          _file('argv.$attempt').readAsLinesSync(),
      ];

  /// The fake's own pid in tunnel [attempt], counting from 1.
  int? attemptPid(int attempt) => _pid('pid.$attempt');

  File _file(String name) => File('${_directory.path}/$name');

  Map<String, String>? _environment(String name) {
    final file = _file(name);
    return file.existsSync()
        ? (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
            .cast<String, String>()
        : null;
  }

  int? _pid(String name) {
    final file = _file(name);
    return file.existsSync()
        ? int.tryParse(file.readAsStringSync().trim())
        : null;
  }

  void _dispose() {
    for (final pids in [_file('pids'), _file('config_children')]) {
      if (!pids.existsSync()) continue;

      for (final pid in pids.readAsLinesSync().map(int.tryParse).nonNulls) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
    }
    deleteSoon(_directory);
  }
}
