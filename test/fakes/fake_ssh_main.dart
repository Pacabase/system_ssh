import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How the fake plays one tunnel attempt.
/// `hang` connects forever, saying nothing.
enum AttemptMode { ready, fail, notFound, bindFailure, hang }

/// Stands in for ssh in the tests, compiled to an executable.
///
/// Copied into a directory as `ssh`, it plays the ssh a test set up in that
/// directory. Otherwise, or after `--steps`, it runs its arguments as steps:
///
/// - `record:<file>` appends this process's pid to the file, then the pid of
///   each child a later step starts.
/// - `err:<line>`, `echo:<text>` or `out:<bytes>` writes to stderr or stdout.
/// - `env:<name>` writes the variable's value, or `<unset>`, to stdout.
/// - `sleep:<milliseconds>`, `exit:<code>` or `hang`.
/// - `spawn` starts a child that hangs.
/// - `late:<line>` starts a child sharing stderr that writes the line
///   shortly after, so after this process has exited.
/// - `hold` starts a child sharing stderr that hangs, holding it open.
Future<void> main(List<String> arguments) async {
  final self = File(Platform.resolvedExecutable);
  final name = self.uri.pathSegments.last.replaceFirst(RegExp(r'\.exe$'), '');

  if (arguments.firstOrNull == '--steps') {
    await _run(arguments.sublist(1));
  } else if (name == 'ssh') {
    await _ssh(self.parent.path, arguments);
  } else {
    await _run(arguments);
  }
}

Future<void> _run(List<String> steps) async {
  File? record;

  Future<void> startChild(List<String> steps, {bool shareStdio = false}) async {
    final file = record ?? (throw StateError('a child needs record: first'));
    final ready = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}');
    final child = await Process.start(
      Platform.resolvedExecutable,
      ['--steps', 'record:${ready.path}', ...steps],
      mode:
          shareStdio ? ProcessStartMode.inheritStdio : ProcessStartMode.normal,
    );
    file.writeAsStringSync('${child.pid}\n', mode: FileMode.append);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!ready.existsSync() || ready.lengthSync() == 0) {
      if (DateTime.now().isAfter(deadline)) throw StateError('child not up');

      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  for (final step in steps) {
    final colon = step.indexOf(':');
    final name = colon < 0 ? step : step.substring(0, colon);
    final value = colon < 0 ? '' : step.substring(colon + 1);

    switch (name) {
      case 'record':
        record = File(value)
          ..writeAsStringSync('$pid\n', mode: FileMode.append);
      case 'err':
        stderr.writeln(value);
      case 'echo':
        stdout.writeln(value);
      case 'env':
        stdout.writeln(Platform.environment[value] ?? '<unset>');
      case 'out':
        stdout.add(List.filled(int.parse(value), 0));
      case 'sleep':
        await Future<void>.delayed(Duration(milliseconds: int.parse(value)));
      case 'spawn':
        await startChild(['hang']);
      case 'late':
        await startChild(['sleep:300', 'err:$value'], shareStdio: true);
      case 'hold':
        await startChild(['hang'], shareStdio: true);
      case 'exit':
        await _flush();
        exit(int.parse(value));
      case 'hang':
        await _flush();
        await Future<void>.delayed(const Duration(hours: 1));
      case 'say':
        // Hangs, writing to stderr each line a test appends to the file.
        await _flush();
        var said = 0;
        while (true) {
          final file = File(value);
          final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
          for (final line in lines.skip(said)) {
            stderr.writeln(line);
          }
          said = lines.length;
          await stderr.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      default:
        throw ArgumentError.value(step, 'step');
    }
  }

  await _flush();
}

Future<void> _flush() async {
  await stdout.flush();
  await stderr.flush();
}

Future<void> _ssh(String directory, List<String> arguments) async {
  File file(String name) => File('$directory/$name');
  String? read(String name) =>
      file(name).existsSync() ? file(name).readAsStringSync() : null;

  file('pids').writeAsStringSync('$pid\n', mode: FileMode.append);

  if (arguments.first == '-G') {
    file('config_argv').writeAsStringSync(arguments.join('\n'));
    file('config_pid').writeAsStringSync('$pid');
    file('config_env').writeAsStringSync(jsonEncode(Platform.environment));

    switch (read('config_mode')) {
      case 'hang':
        return _run(['hang']);
      case 'hang-with-child':
        return _run(
            ['record:${file('config_children').path}', 'spawn', 'hang']);
      case 'fail':
        return _run(['err:fake ssh: -G failed', 'exit:1']);
    }

    stdout.write(read('config') ?? '');
    return _run([]);
  }

  if (arguments.contains('-O')) return _mux(directory, arguments);

  var attempt = 1;
  while (file('argv.$attempt').existsSync()) {
    attempt++;
  }
  file('argv.$attempt').writeAsStringSync(arguments.join('\n'));
  file('pid.$attempt').writeAsStringSync('$pid');
  file('env.$attempt').writeAsStringSync(jsonEncode(Platform.environment));

  final modes = (read('modes') ?? AttemptMode.ready.name)
      .split('\n')
      .map(AttemptMode.values.byName)
      .toList();
  final mode = attempt <= modes.length ? modes[attempt - 1] : modes.last;
  if (arguments.contains('ControlMaster=yes')) {
    return _run(switch (mode) {
      AttemptMode.ready => [
          'err:debug1: setting up multiplex master socket',
          'err:debug1: Entering interactive session.',
          'say:${file('master_say').path}',
        ],
      AttemptMode.fail || AttemptMode.bindFailure => [
          'err:ssh: connect to host ssh.example.com port 22: Connection refused',
          'exit:255',
        ],
      AttemptMode.notFound => ['err:sh: 1: ssh: not found', 'exit:127'],
      AttemptMode.hang => ['hang'],
    });
  }

  final forward =
      arguments.indexWhere((argument) => ['-L', '-D', '-R'].contains(argument));
  final spec = arguments[forward + 1].split(':');
  final port = spec[1];

  if (arguments[forward] == '-R') {
    // A remote port of 0 has the server pick 41234.
    final destination = '${spec[2]}:${spec[3]}';
    final listen = port == '0' ? '41234' : port;
    final answer = 'listen 127.0.0.1:$port, connect $destination';
    return _run(switch (mode) {
      AttemptMode.ready => [
          'err:debug1: Entering interactive session.',
          'err:debug1: remote forward success for: $answer',
          if (port == '0')
            'err:Allocated port $listen for remote forward to $destination',
          'hang',
        ],
      AttemptMode.fail => [
          'err:ssh: connect to host ssh.example.com port 22: Connection refused',
          'exit:255',
        ],
      AttemptMode.notFound => ['err:sh: 1: ssh: not found', 'exit:127'],
      AttemptMode.hang => ['hang'],
      AttemptMode.bindFailure => [
          'err:debug1: Entering interactive session.',
          'err:debug1: remote forward failure for: $answer',
          'err:Error: remote port forwarding failed for listen port $port',
          'exit:255',
        ],
    });
  }

  final listening =
      'debug1: Local forwarding listening on 127.0.0.1 port $port.';

  await _run(switch (mode) {
    AttemptMode.ready => [
        'err:$listening',
        'err:debug1: Entering interactive session.',
        'hang',
      ],
    AttemptMode.fail => [
        'err:ssh: connect to host ssh.example.com port 22: Connection refused',
        'exit:255',
      ],
    AttemptMode.notFound => ['err:sh: 1: ssh: not found', 'exit:127'],
    AttemptMode.hang => ['hang'],
    AttemptMode.bindFailure => [
        'err:$listening',
        'err:bind [127.0.0.1]:$port: Address already in use',
        'err:channel_setup_fwd_listener_tcpip: cannot listen to port: $port',
        'err:Could not request local forwarding.',
        'exit:255',
      ],
  });
}

/// `ssh -O forward|cancel`: records its arguments as `mux.<n>`, and answers
/// per the `mux_modes` file, one line per command: `ok`, `fail` or
/// `silent-fail` (fails but exits 0, as `-O cancel` does).
Future<void> _mux(String directory, List<String> arguments) async {
  File file(String name) => File('$directory/$name');

  var command = 1;
  while (file('mux.$command').existsSync()) {
    command++;
  }
  file('mux.$command').writeAsStringSync(arguments.join('\n'));

  final modesFile = file('mux_modes');
  final modes = modesFile.existsSync() ? modesFile.readAsLinesSync() : ['ok'];
  final mode = command <= modes.length ? modes[command - 1] : modes.last;
  final operation = arguments[arguments.indexOf('-O') + 1];
  final spec = arguments[arguments.indexOf('-O') + 3];

  await _run(switch (mode) {
    'fail' => [
        'err:mux_client_forward: forwarding request failed: Port forwarding failed',
        'err:muxclient: master forward request failed',
        'exit:255',
      ],
    'silent-fail' => [
        'err:mux_client_forward: forwarding request failed: port not forwarded',
        'err:muxclient: master cancel forward request failed',
        'exit:0',
      ],
    _ => [
        if (operation == 'forward' && spec.startsWith('127.0.0.1:0:'))
          'echo:41234',
        'exit:0',
      ],
  });
}
