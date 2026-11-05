import 'package:system_ssh/src/failure_message.dart';
import 'package:test/test.dart';

void main() {
  test('ignores blank lines', () {
    expect(
      failureMessage([
        'debug1: Connecting to ssh.example.com',
        '',
        'bind [127.0.0.1]:50000: Address already in use',
        '  ',
      ]),
      'bind [127.0.0.1]:50000: Address already in use',
    );
  });

  test('keeps only the lines that are not ssh -v progress or its banner', () {
    expect(
      failureMessage([
        'OpenSSH_9.6p1, LibreSSL 3.3.6',
        'debug1: Reading configuration data /etc/ssh/ssh_config',
        'debug2: resolving "nope" port 22',
        'ssh: Could not resolve hostname nope',
        "Warning: Permanently added 'ssh.example.com' (ED25519) to the list of known hosts.",
        'Authenticated to ssh.example.com ([10.0.0.1]:22) using "publickey".',
        'Transferred: sent 2104, received 1996 bytes, in 0.1 seconds',
        'Bytes per second: sent 21040.0, received 19960.0',
        'debug3: Exit status 255',
        'kex_exchange_identification: Connection closed',
      ]),
      'ssh: Could not resolve hostname nope\n'
      'kex_exchange_identification: Connection closed',
    );
  });

  test('has no headline, only the reason', () {
    expect(
      failureMessage(['Host key verification failed.']),
      'Host key verification failed.',
    );
  });

  test('falls back to the last three lines when all are progress', () {
    expect(
      failureMessage([
        'OpenSSH_9.6p1, LibreSSL 3.3.6',
        'debug1: one',
        'Authenticated to ssh.example.com',
        'debug1: three',
      ]),
      'debug1: one\n'
      'Authenticated to ssh.example.com\n'
      'debug1: three',
    );
  });

  test('falls back to every line of a log shorter than three', () {
    expect(
      failureMessage(['debug1: one', 'debug1: two']),
      'debug1: one\ndebug1: two',
    );
  });

  test('is empty for an empty log', () {
    expect(failureMessage([]), isEmpty);
  });

  test('is empty for a log of blank lines', () {
    expect(failureMessage(['', '   ']), isEmpty);
  });

  group('isPermanentFailure', () {
    for (final line in [
      'Host key verification failed.',
      '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @',
      'user@ssh.example.com: Permission denied (publickey).',
      'Received disconnect from 10.0.0.1 port 22:2: Too many authentication failures',
      '/Users/me/.ssh/config: line 4: Bad configuration option: hostnme',
      'Bad owner or permissions on /Users/me/.ssh/config',
      '/Users/me/.ssh/config line 2: no argument after keyword "hostname"',
      '/Users/me/.ssh/config line 3: garbage at end of line; "x".',
    ]) {
      test('is true for "$line"', () {
        expect(isPermanentFailure(['debug1: Connecting', line]), isTrue);
      });
    }

    for (final line in [
      'Connection to ssh.example.com closed by remote host.',
      'Timeout, server ssh.example.com not responding.',
      'ssh: connect to host ssh.example.com port 22: Connection refused',
      'ssh: connect to host ssh.example.com port 22: Operation timed out',
      'ssh: Could not resolve hostname ssh.example.com: nodename nor servname provided, or not known',
      'client_loop: send disconnect: Broken pipe',
      'Connection reset by 10.0.0.1 port 22',
      // How Windows' ssh says a local port is taken.
      'bind [127.0.0.1]:56882: Permission denied',
    ]) {
      test('is false for "$line"', () {
        expect(isPermanentFailure(['debug1: Connecting', line]), isFalse);
      });
    }

    test('ignores ssh -v progress', () {
      expect(
        isPermanentFailure([
          'debug1: Next authentication method: publickey',
          'debug1: Permission denied for one key, trying the next',
          'Connection to ssh.example.com closed by remote host.',
        ]),
        isFalse,
      );
    });
  });
}
