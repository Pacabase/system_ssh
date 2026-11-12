import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  group('SshException', () {
    test('keeps its message and names itself in toString', () {
      const exception = SshException('boom');

      expect(exception.message, 'boom');
      expect(exception.toString(), 'SshException: boom');
    });

    test('is not permanent', () {
      expect(const SshException('boom').isPermanent, isFalse);
    });
  });

  group('SshNotFoundException', () {
    test('is a permanent SshException', () {
      expect(SshNotFoundException(), isA<SshException>());
      expect(SshNotFoundException().isPermanent, isTrue);
    });

    test('says to install OpenSSH', () {
      expect(
        SshNotFoundException().toString(),
        'SshNotFoundException: '
        'ssh was not found; install OpenSSH and put it on the PATH',
      );
    });

    test('says to add the OpenSSH Client feature on Windows', () {
      expect(
        SshNotFoundException(onWindows: true).toString(),
        'SshNotFoundException: ssh was not found; '
        'add "OpenSSH Client" in Settings under Optional features',
      );
    });
  });

  group('SshTunnelAbortedException', () {
    test('says the tunnel was aborted', () {
      const exception = SshTunnelAbortedException();

      expect(exception, isA<SshException>());
      expect(exception.isPermanent, isFalse);
      expect(
        exception.toString(),
        'SshTunnelAbortedException: the tunnel was aborted',
      );
    });
  });

  group('SshTunnelException', () {
    test('keeps its message, log and exit code', () {
      const exception = SshTunnelException(
        'Connection refused',
        log: ['debug1: Connecting', 'Connection refused'],
        exitCode: 255,
      );

      expect(exception, isA<SshException>());
      expect(exception.message, 'Connection refused');
      expect(exception.log, ['debug1: Connecting', 'Connection refused']);
      expect(exception.exitCode, 255);
      expect(exception.toString(), 'SshTunnelException: Connection refused');
    });

    test('has an empty log and no exit code by default', () {
      const exception = SshTunnelException('boom');

      expect(exception.log, isEmpty);
      expect(exception.exitCode, isNull);
    });
  });

  group('SshPortInUseException', () {
    test('keeps its port and says it is in use', () {
      const exception = SshPortInUseException(5432);

      expect(exception, isA<SshException>());
      expect(exception.isPermanent, isTrue);
      expect(exception.port, 5432);
      expect(
        exception.toString(),
        'SshPortInUseException: 127.0.0.1:5432 is already in use',
      );
    });
  });
}
