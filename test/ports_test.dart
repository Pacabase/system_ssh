import 'dart:io';

import 'package:system_ssh/src/exceptions.dart';
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

  test('isPortFree checks the address it is given', () async {
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(socket.close);

    expect(await isPortFree(socket.port, address: '0.0.0.0'), isFalse);
    expect(
        await isPortFree(await pickFreePort(address: '0.0.0.0'),
            address: '0.0.0.0'),
        isTrue);
  });

  test('isPortFree on :: leaves IPv4 alone, as ssh does', () async {
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(socket.close);

    expect(await isPortFree(socket.port, address: '::'), isTrue);
  });

  // 192.0.2.1 is TEST-NET-1, kept for documentation, so no computer has it.
  test('says an address is not this computer\'s, rather than taken', () async {
    await expectLater(
      isPortFree(5432, address: '192.0.2.1'),
      throwsA(
        isA<SshException>().having(
          (exception) => exception.message,
          'message',
          "192.0.2.1 isn't an address of this computer",
        ),
      ),
    );
    await expectLater(
      pickFreePort(address: '192.0.2.1'),
      throwsA(isA<SshException>()),
    );
  });
}
