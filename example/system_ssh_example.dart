import 'dart:async';
import 'dart:io';

import 'package:system_ssh/system_ssh.dart';

Future<void> main() async {
  const client = SystemSshClient();

  final SshTunnel tunnel;
  try {
    tunnel = await client.openTunnel(
      const SshTarget('ssh.example.com'),
      remoteHost: 'db.example.com',
      remotePort: 5432,
    );
  } on SshTunnelException catch (exception) {
    stderr.writeln('ssh failed: ${exception.message}');
    exitCode = 1;
    return;
  } on SshException catch (exception) {
    stderr.writeln(exception.message);
    exitCode = 1;
    return;
  }

  print('db.example.com:5432 is on 127.0.0.1:${tunnel.localPort}');
  await Future.any([ProcessSignal.sigint.watch().first, tunnel.done]);
  await tunnel.close();
}
