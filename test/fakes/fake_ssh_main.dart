import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How the fake plays one tunnel attempt. `hang` connects forever, saying
/// nothing; `held`, for a master, says only what a test has it say, so the
/// test finishes its login.
enum AttemptMode { ready, fail, notFound, bindFailure, hang, held }

/// How the fake's server key plays, before any [AttemptMode]: `unknown` until
/// the fake's own `known_hosts` holds [fakeHostKeyEntry], `changed`, or
/// `jump-unknown` for a ProxyJump host that isn't known.
enum HostKeyMode { unknown, changed, jumpUnknown }

/// How the fake answers the ssh that reads a host key to trust it:
/// - `adds` writes [fakeHostKeyEntry];
/// - `addsOther` writes [otherHostKeyEntry] while its log, as a server's
///   banner could, names [fakeHostKeyFingerprint];
/// - `checkHostIp` writes the key twice, hashed and for the host's address;
/// - `authenticates` writes it, logs in with `none`, then hangs;
/// - `viaJump` logs in to a ProxyJump host first, then adds the key;
/// - `jumpOnly` knows the jump host, then can't reach the server;
/// - `known` finds it already known, `changed` finds another key known;
/// - `unreachable` never connects, and `hang` never answers.
enum TrustMode {
  adds,
  addsOther,
  checkHostIp,
  authenticates,
  viaJump,
  jumpOnly,
  known,
  changed,
  unreachable,
  hang,
}

const fakeHostKeyName = '[ssh.example.com]:2222';

/// What `ssh-keygen -lf` prints for [fakeHostKeyEntry]'s key.
const fakeHostKeyFingerprint =
    'SHA256:JXCfe3dR9EQIJhqY/0OVqgU3aWg86KomYCIgZiW2EHI';

/// What `ssh-keygen -lf` prints for [otherHostKeyEntry]'s key.
const otherHostKeyFingerprint =
    'SHA256:kDPTSEV9vPg8kh2Fn51kOtrobtrv8zEUGwO5NUqDhqg';
const _fakeHostKey =
    'AAAAC3NzaC1lZDI1NTE5AAAAIGZha2UgaG9zdCBrZXkgZm9yIHRoZSB0ZXN0cyBvbmx5';
const _otherHostKey =
    'AAAAC3NzaC1lZDI1NTE5AAAAIG90aGVyIGhvc3Qga2V5IGZvciB0aGUgdGVzdHMhISEh';
const fakeHostKeyEntry = '$fakeHostKeyName ssh-ed25519 $_fakeHostKey';
const otherHostKeyEntry = '$fakeHostKeyName ssh-ed25519 $_otherHostKey';

/// [fakeHostKeyEntry] as `HashKnownHosts` and `CheckHostIP` write it.
const checkHostIpEntries = [
  '|1|c2FsdA==|aGFzaA== ssh-ed25519 $_fakeHostKey',
  '|1|c2FsdDI=|aGFzaDI= ssh-ed25519 $_fakeHostKey',
];

List<String> _changedKey(String fingerprint) => [
      'err:debug1: Server host key: ssh-ed25519 $fingerprint',
      'err:@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@',
      'err:@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @',
      'err:@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@',
      'err:IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!',
      'err:The fingerprint for the ED25519 key sent by the remote host is',
      'err:$fingerprint.',
      'err:Please contact your system administrator.',
      'err:Offending ED25519 key in /home/user/.ssh/known_hosts:3',
      'err:Host key for $fakeHostKeyName has changed and you have requested strict checking.',
      'err:Host key verification failed.',
      'exit:255',
    ];

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
/// - `write:<file>=<line>` appends the line to the file.
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
      case 'write':
        final equals = value.indexOf('=');
        File(value.substring(0, equals)).writeAsStringSync(
          '${value.substring(equals + 1)}\n',
          mode: FileMode.append,
        );
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
  if (arguments.contains('PreferredAuthentications=none')) {
    return _trust(directory, arguments);
  }

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

  final knownHosts = read('known_hosts') ?? '';
  final hostKeyMode = switch (read('host_key_mode')) {
    final name? => HostKeyMode.values.byName(name),
    null => null,
  };
  switch (hostKeyMode) {
    case HostKeyMode.unknown when !knownHosts.contains(fakeHostKeyEntry):
      return _run([
        'err:debug1: Connecting to ssh.example.com port 2222.',
        'err:debug1: Server host key: ssh-ed25519 $fakeHostKeyFingerprint',
        'err:No ED25519 host key is known for $fakeHostKeyName and you have requested strict checking.',
        'err:Host key verification failed.',
        'exit:255',
      ]);
    case HostKeyMode.changed:
      return _run(_changedKey(fakeHostKeyFingerprint));
    case HostKeyMode.jumpUnknown:
      return _run([
        'err:debug1: Connecting to jump.example.com port 22.',
        'err:debug1: Server host key: ssh-ed25519 $otherHostKeyFingerprint',
        "err:debug1: read_passphrase: can't open /dev/tty: Device not configured",
        'err:Host key verification failed.',
        'err:kex_exchange_identification: Connection closed by remote host',
        'err:Connection closed by UNKNOWN port 65535',
        'exit:255',
      ]);
    case HostKeyMode.unknown || null:
      break;
  }

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
      AttemptMode.held => ['say:${file('master_say').path}'],
    });
  }

  final forward =
      arguments.indexWhere((argument) => ['-L', '-D', '-R'].contains(argument));
  // A bracketed IPv6 address holds colons of its own.
  final bracketed = RegExp(r'^\[([^\]]*)\]:(.*)').firstMatch(
    arguments[forward + 1],
  );
  final spec = bracketed == null
      ? arguments[forward + 1].split(':')
      : [bracketed[1]!, ...bracketed[2]!.split(':')];
  final address = spec[0];
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
      AttemptMode.hang || AttemptMode.held => ['hang'],
      AttemptMode.bindFailure => [
          'err:debug1: Entering interactive session.',
          'err:debug1: remote forward failure for: $answer',
          'err:Error: remote port forwarding failed for listen port $port',
          'exit:255',
        ],
    });
  }

  final listening =
      'debug1: Local forwarding listening on $address port $port.';

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
    AttemptMode.hang || AttemptMode.held => ['hang'],
    AttemptMode.bindFailure => [
        'err:$listening',
        'err:bind [$address]:$port: Address already in use',
        'err:channel_setup_fwd_listener_tcpip: cannot listen to port: $port',
        'err:Could not request local forwarding.',
        'exit:255',
      ],
  });
}

/// The ssh that reads a host key to trust it: records its arguments as
/// `trust_argv` and answers per the `trust_mode` file.
Future<void> _trust(String directory, List<String> arguments) async {
  File file(String name) => File('$directory/$name');
  file('trust_argv').writeAsStringSync(arguments.join('\n'));

  final option = arguments.firstWhere(
    (argument) => argument.startsWith('UserKnownHostsFile='),
  );
  final readInto = File(RegExp('"([^"]+)"').firstMatch(option)![1]!);
  final mode = file('trust_mode').existsSync()
      ? TrustMode.values.byName(file('trust_mode').readAsStringSync())
      : TrustMode.adds;
  const fingerprint = fakeHostKeyFingerprint;
  const denied =
      'err:user@ssh.example.com: Permission denied (publickey,password).';
  const added = [
    'err:debug1: Connecting to ssh.example.com port 2222.',
    'err:debug1: Server host key: ssh-ed25519 $fingerprint',
    "err:Warning: Permanently added '$fakeHostKeyName' (ED25519) to the list of known hosts.",
  ];

  switch (mode) {
    case TrustMode.adds || TrustMode.authenticates:
      readInto.writeAsStringSync('$fakeHostKeyEntry\n');
    case TrustMode.addsOther:
      readInto.writeAsStringSync('$otherHostKeyEntry\n');
    case TrustMode.checkHostIp:
      readInto.writeAsStringSync(checkHostIpEntries.map((e) => '$e\n').join());
    case _:
  }
  await _run(switch (mode) {
    TrustMode.adds || TrustMode.checkHostIp => [...added, denied, 'exit:255'],
    // A man in the middle's banner, after its key exchange, claims both.
    TrustMode.addsOther => [
        ...added,
        ..._changedKey(fingerprint).where((step) => step != 'exit:255'),
        denied,
        'exit:255',
      ],
    TrustMode.viaJump => [
        "err:debug1: Host 'jump.example.com' is known and matches the ED25519 host key.",
        'err:Authenticated to jump.example.com ([10.0.0.2]:22) using "publickey".',
        'sleep:200',
        'write:${readInto.path}=$fakeHostKeyEntry',
        ...added,
        denied,
        'exit:255',
      ],
    TrustMode.jumpOnly => [
        "err:debug1: Host 'jump.example.com' is known and matches the ED25519 host key.",
        'err:Authenticated to jump.example.com ([10.0.0.2]:22) using "publickey".',
        'err:channel 0: open failed: connect failed: Connection refused',
        'err:kex_exchange_identification: Connection closed by remote host',
        'exit:255',
      ],
    TrustMode.authenticates => [
        ...added,
        'err:Authenticated to ssh.example.com ([10.0.0.1]:2222) using "none".',
        'hang',
      ],
    TrustMode.hang => ['hang'],
    TrustMode.known => [
        'err:debug1: Server host key: ssh-ed25519 $fingerprint',
        "err:debug1: Host '$fakeHostKeyName' is known and matches the ED25519 host key.",
        denied,
        'exit:255',
      ],
    TrustMode.changed => _changedKey(otherHostKeyFingerprint),
    TrustMode.unreachable => [
        'err:ssh: connect to host ssh.example.com port 2222: Connection refused',
        'exit:255',
      ],
  });
}

/// `ssh -O forward|cancel`: records its arguments as `mux.<n>`, and answers
/// per the `mux_modes` file, one line per command: `ok`, `quiet` (prints no
/// port), `slow` (answers after 300 ms), `hang`, `fail` or `silent-fail`
/// (fails but exits 0, as `-O cancel` does).
Future<void> _mux(String directory, List<String> arguments) async {
  File file(String name) => File('$directory/$name');

  // Commands run at once must not take the same record.
  var command = 1;
  while (true) {
    try {
      file('mux.$command').createSync(exclusive: true);
      break;
    } on FileSystemException {
      command++;
    }
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
    'hang' => ['hang'],
    'quiet' => ['exit:0'],
    _ => [
        if (mode == 'slow') 'sleep:300',
        if (operation == 'forward' && spec.startsWith('127.0.0.1:0:'))
          'echo:41234',
        'exit:0',
      ],
  });
}
