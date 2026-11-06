import 'dart:io';

/// Runs `ssh -F <its directory>/config` with its arguments, so the
/// integration tests on Windows never read the user's `~/.ssh/config`.
///
/// As a ProxyCommand's `ssh -W`, it writes that ssh's pid to
/// `<its directory>/proxy.pid`.
Future<void> main(List<String> arguments) async {
  final directory = File(Platform.resolvedExecutable).parent.path;
  final ssh = await Process.start(
    'ssh',
    ['-F', '$directory\\config', ...arguments],
    mode: ProcessStartMode.inheritStdio,
  );
  if (arguments.contains('-W')) {
    File('$directory\\proxy.pid').writeAsStringSync('${ssh.pid}');
  }

  exit(await ssh.exitCode);
}
