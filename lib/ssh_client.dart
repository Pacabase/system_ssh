/// The types an app codes against: `SshClient`, to pass around or fake, with
/// its tunnels, logs, targets, host keys and exceptions, and the commands
/// that open the same tunnels from a terminal.
///
/// It leaves out `SystemSshClient` and the process handling behind it, and
/// imports no `dart:io`, so code that only takes an `SshClient`, such as UI
/// or a fake in tests, depends on nothing that starts ssh.
/// `package:system_ssh/system_ssh.dart` exports all of it too.
library;

export 'src/exceptions.dart';
export 'src/ssh_client.dart';
export 'src/ssh_host_key.dart';
export 'src/ssh_log.dart';
export 'src/ssh_target.dart';
export 'src/terminal_command.dart';
