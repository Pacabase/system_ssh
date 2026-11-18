import 'dart:io';

import 'package:system_ssh/src/exceptions.dart';
import 'package:system_ssh/src/ports.dart';
import 'package:test/test.dart';

// Other test files run at once and bind ports too, so one may take a picked
// port before the test does: these tests try a few, and a real fault fails
// every try.
const _tries = 5;

bool _isInUse(SocketException exception) =>
    const {48, 98, 10048}.contains(exception.osError?.errorCode);

void main() {
  test('pickFreePort returns a loopback port that can be bound', () async {
    for (var attempt = 1;; attempt++) {
      final port = await pickFreePort();
      expect(port, inInclusiveRange(1024, 65535));
      try {
        await (await ServerSocket.bind(InternetAddress.loopbackIPv4, port))
            .close();
        return;
      } on SocketException catch (exception) {
        if (!_isInUse(exception) || attempt == _tries) rethrow;
      }
    }
  });

  test('isPortFree is true for a port nothing holds', () async {
    for (var attempt = 1; attempt <= _tries; attempt++) {
      if (await isPortFree(await pickFreePort())) return;
    }
    fail('every picked port was in use');
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
        isA<SshAddressUnavailableException>().having(
          (exception) => exception.message,
          'message',
          "192.0.2.1 isn't an address of this computer",
        ),
      ),
    );
    await expectLater(
      pickFreePort(address: '192.0.2.1'),
      throwsA(isA<SshAddressUnavailableException>()),
    );
  });
}
