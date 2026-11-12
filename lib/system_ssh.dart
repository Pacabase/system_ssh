/// SSH tunnels through the system's own `ssh`, so `~/.ssh/config`, agents
/// and `ProxyJump` work exactly as they do in a terminal.
///
/// Code that only takes an `SshClient` can import
/// `package:system_ssh/interface.dart` instead, which has everything here but
/// `SystemSshClient`.
library;

export 'interface.dart';
export 'src/system_ssh_client.dart' show SystemSshClient;
