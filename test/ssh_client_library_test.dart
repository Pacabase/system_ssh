import 'dart:io';

import 'package:system_ssh/ssh_client.dart';
import 'package:test/test.dart';

/// A fake that needs nothing but ssh_client.dart.
final class _FakeSshClient implements SshClient {
  @override
  Future<SshTunnel> openTunnel(
    SshTarget server, {
    required String remoteHost,
    required int remotePort,
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) async =>
      throw SshNotFoundException();

  @override
  Future<SshTunnel> openSocketTunnel(
    SshTarget server, {
    required String remoteSocket,
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) =>
      throw UnimplementedError();

  @override
  Future<SshRemoteTunnel> openRemoteTunnel(
    SshTarget server, {
    String localHost = 'localhost',
    required int localPort,
    int? remotePort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) =>
      throw UnimplementedError();

  @override
  Future<SshTunnel> openSocksProxy(
    SshTarget server, {
    String bindAddress = '127.0.0.1',
    int? localPort,
    void Function(SshLog log)? onLog,
    Future<void>? abortTrigger,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> trustHostKey(
    SshTarget server,
    SshHostKey hostKey, {
    Future<void>? abortTrigger,
  }) async {}

  @override
  Future<List<String>> configuredHosts() async => const [];
}

// What starts processes or loads native code.
final _native = RegExp(
  r'''^(?:import|export)\s+['"](dart:io|dart:ffi|dart:isolate|package:ffi/)''',
);
final _local = RegExp(
  r'''^(?:import|export)\s+['"](?:package:system_ssh/)?([^':]+\.dart)['"]''',
);

void main() {
  test('a fake SshClient needs only ssh_client.dart', () async {
    final SshClient client = _FakeSshClient();

    await expectLater(
      client.openTunnel(
        const SshTarget('ssh.example.com'),
        remoteHost: 'db.example.com',
        remotePort: 5432,
      ),
      throwsA(isA<SshNotFoundException>()),
    );
    expect(
      tunnelCommand(
        const SshTarget('ssh.example.com'),
        remoteHost: 'db.example.com',
        remotePort: 5432,
        localPort: 15432,
      ),
      startsWith('ssh -N -L'),
    );
  });

  test('nothing ssh_client.dart reaches imports dart:io', () {
    final seen = <String>{};
    final offenders = <String>[];

    void visit(String path) {
      if (!seen.add(path)) return;

      final file = File(path);
      for (final line in file.readAsLinesSync()) {
        if (_native.hasMatch(line)) offenders.add('$path: $line');
        if (_local.firstMatch(line)?[1] case final target?) {
          visit(
            // Forward slashes on every OS, which File takes on Windows too.
            line.contains('package:system_ssh/')
                ? 'lib/$target'
                : Uri(path: path).resolve(target).path,
          );
        }
      }
    }

    visit('lib/ssh_client.dart');

    expect(seen, contains('lib/src/exceptions.dart'));
    expect(offenders, isEmpty);
  });
}
