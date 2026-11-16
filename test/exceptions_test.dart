import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  const hostKey = SshHostKey(
    host: 'ssh.example.com',
    type: 'ED25519',
    fingerprint: 'SHA256:abc',
  );

  group('permanent', () {
    for (final (exception, name) in <(SshException, String)>[
      (SshNotFoundException(), 'SshNotFoundException'),
      (const SshConfigException('boom'), 'SshConfigException'),
      (const SshPortInUseException(5432), 'SshPortInUseException'),
      (
        const SshDuplicateForwardException('127.0.0.1:0:localhost:3000'),
        'SshDuplicateForwardException',
      ),
      (const SshLoginRefusedException('boom'), 'SshLoginRefusedException'),
      (const SshHostKeyRefusedException('boom'), 'SshHostKeyRefusedException'),
      (SshUnknownHostKeyException(hostKey), 'SshUnknownHostKeyException'),
      (SshHostKeyChangedException(hostKey), 'SshHostKeyChangedException'),
    ]) {
      test('$name is an SshPermanentException named in toString', () {
        expect(exception, isA<SshPermanentException>());
        expect(exception.toString(), '$name: ${exception.message}');
      });
    }
  });

  group('temporary', () {
    for (final (exception, name) in <(SshException, String)>[
      (const SshHostNotFoundException('boom'), 'SshHostNotFoundException'),
      (const SshUnreachableException('boom'), 'SshUnreachableException'),
      (const SshDroppedException('boom'), 'SshDroppedException'),
      (
        const SshAddressUnavailableException('10.0.0.9'),
        'SshAddressUnavailableException',
      ),
      (const SshFailedException('boom'), 'SshFailedException'),
    ]) {
      test('$name is an SshTemporaryException named in toString', () {
        expect(exception, isA<SshTemporaryException>());
        expect(exception.toString(), '$name: ${exception.message}');
      });
    }
  });

  test('keeps the message, log and exit code a fake passes', () {
    const exception = SshUnreachableException(
      'Connection refused',
      log: ['debug1: Connecting', 'Connection refused'],
      exitCode: 255,
    );

    expect(exception.message, 'Connection refused');
    expect(exception.log, ['debug1: Connecting', 'Connection refused']);
    expect(exception.exitCode, 255);
  });

  test('has an empty log and no exit code by default', () {
    const exception = SshFailedException('boom');

    expect(exception.log, isEmpty);
    expect(exception.exitCode, isNull);
  });

  group('SshNotFoundException', () {
    test('says to install OpenSSH', () {
      expect(
        SshNotFoundException().message,
        'ssh was not found; install OpenSSH and put it on the PATH',
      );
    });

    test('says to add the OpenSSH Client feature on Windows', () {
      expect(
        SshNotFoundException(onWindows: true).message,
        'ssh was not found; '
        'add "OpenSSH Client" in Settings under Optional features',
      );
    });
  });

  test('SshTunnelAbortedException is neither permanent nor temporary', () {
    const exception = SshTunnelAbortedException();

    expect(exception, isNot(isA<SshPermanentException>()));
    expect(exception, isNot(isA<SshTemporaryException>()));
    expect(
      exception.toString(),
      'SshTunnelAbortedException: the tunnel was aborted',
    );
  });

  test('SshPortInUseException keeps its port and address', () {
    const exception = SshPortInUseException(5432, address: '172.17.0.1');

    expect(exception.port, 5432);
    expect(exception.address, '172.17.0.1');
    expect(exception.message, '172.17.0.1:5432 is already in use');
    expect(
      const SshPortInUseException(5432).message,
      '127.0.0.1:5432 is already in use',
    );
  });

  test('SshAddressUnavailableException keeps its address', () {
    const exception = SshAddressUnavailableException('10.0.0.9');

    expect(exception.address, '10.0.0.9');
    expect(exception.message, "10.0.0.9 isn't an address of this computer");
  });
}
