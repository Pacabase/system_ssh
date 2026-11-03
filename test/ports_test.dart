import 'dart:io';

import 'package:system_ssh/src/ports.dart';
import 'package:test/test.dart';

void main() {
  test('pickFreePort returns a loopback port that can be bound', () async {
    final port = await pickFreePort();
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();

    expect(port, inInclusiveRange(1024, 65535));
  });

  test('isPortFree is true for a port nothing holds', () async {
    expect(await isPortFree(await pickFreePort()), isTrue);
  });

  test('isPortFree is false for a bound port', () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(socket.close);

    expect(await isPortFree(socket.port), isFalse);
  });
}
