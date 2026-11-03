import 'dart:io';

/// Runs `ssh -F <its directory>/config` with its arguments, so the
/// integration tests on Windows never read the user's `~/.ssh/config`.
Future<void> main(List<String> arguments) async {
  final config = '${File(Platform.resolvedExecutable).parent.path}\\config';
  final ssh = await Process.start(
    'ssh',
    ['-F', config, ...arguments],
    mode: ProcessStartMode.inheritStdio,
  );

  exit(await ssh.exitCode);
}
