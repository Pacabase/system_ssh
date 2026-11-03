import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  group('SshException', () {
    test('keeps its message and names itself in toString', () {
      const exception = SshException('boom');

      expect(exception.message, 'boom');
      expect(exception.toString(), 'SshException: boom');
    });
  });

  group('SshNotFoundException', () {
    test('says to install OpenSSH', () {
      const exception = SshNotFoundException();

      expect(exception, isA<SshException>());
      expect(
        exception.toString(),
        'SshNotFoundException: '
        'ssh was not found; install OpenSSH and put it on the PATH',
      );
    });
  });

  group('SshTunnelAbortedException', () {
    test('says the tunnel was aborted', () {
      const exception = SshTunnelAbortedException();

      expect(exception, isA<SshException>());
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
}
