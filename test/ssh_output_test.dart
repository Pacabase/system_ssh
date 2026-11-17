import 'package:system_ssh/src/ssh_output.dart';
import 'package:system_ssh/system_ssh.dart';
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

  group('tunnelFailure', () {
    for (final (line, type) in [
      ('Host key verification failed.', SshHostKeyRefusedException),
      (
        'Unable to negotiate with 10.0.0.1 port 22: no matching host key type found. Their offer: ssh-rsa',
        SshConfigException,
      ),
      (
        'user@ssh.example.com: Permission denied (publickey).',
        SshLoginRefusedException,
      ),
      ('Permission denied (publickey).', SshLoginRefusedException),
      (
        'ssh.example.com: Permission denied (publickey,password).',
        SshLoginRefusedException,
      ),
      (
        'Received disconnect from 10.0.0.1 port 22:2: Too many authentication failures',
        SshLoginRefusedException,
      ),
      (
        '/Users/me/.ssh/config: line 4: Bad configuration option: hostnme',
        SshConfigException,
      ),
      ('Bad owner or permissions on /Users/me/.ssh/config', SshConfigException),
      (
        '/Users/me/.ssh/config line 2: no argument after keyword "hostname"',
        SshConfigException,
      ),
      (
        '/Users/me/.ssh/config line 3: garbage at end of line; "x".',
        SshConfigException,
      ),
      (
        'ssh: Could not resolve hostname ssh.example.com: nodename nor servname provided, or not known',
        SshHostNotFoundException,
      ),
      (
        'Connection to ssh.example.com closed by remote host.',
        SshDroppedException,
      ),
      (
        'Timeout, server ssh.example.com not responding.',
        SshDroppedException,
      ),
      ('client_loop: send disconnect: Broken pipe', SshDroppedException),
      ('Connection reset by 10.0.0.1 port 22', SshDroppedException),
      (
        'ssh: connect to host ssh.example.com port 22: Connection refused',
        SshUnreachableException,
      ),
      (
        'ssh: connect to host ssh.example.com port 22: Operation timed out',
        SshUnreachableException,
      ),
      (
        'ssh: connect to host ssh.example.com port 22: No route to host',
        SshUnreachableException,
      ),
      (
        'kex_exchange_identification: read: Connection reset by peer',
        SshUnreachableException,
      ),
      (
        'Connection timed out during banner exchange',
        SshUnreachableException,
      ),
      (
        'ssh_exchange_identification: read: Connection reset by peer',
        SshUnreachableException,
      ),
      ('Connection closed by 10.0.0.1 port 22', SshDroppedException),
      (
        'client_loop: send disconnect: Connection reset by peer',
        SshDroppedException,
      ),
      (
        'ssh_dispatch_run_fatal: Connection to 10.0.0.1 port 22: Operation timed out',
        SshDroppedException,
      ),
      // How Windows' ssh says a local port is taken.
      ('bind [127.0.0.1]:56882: Permission denied', SshFailedException),
      ('something ssh has never said', SshFailedException),
    ]) {
      test('is an $type for "$line"', () {
        final failure = tunnelFailure(['debug1: Connecting', line], 255);

        expect(failure.runtimeType, type);
        expect(failure.message, line);
        expect(failure.exitCode, 255);
        expect(failure.log, ['debug1: Connecting', line]);
      });
    }

    test('puts a login refused before the disconnect that follows it', () {
      expect(
        tunnelFailure([
          'Received disconnect from 10.0.0.1 port 22:2: Too many authentication failures',
          'Disconnected from 10.0.0.1 port 22',
        ], 255),
        isA<SshLoginRefusedException>(),
      );
    });

    test("isn't a refused host key for ssh's warning alone", () {
      expect(
        tunnelFailure([
          '@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @',
          'Password authentication is disabled to avoid man-in-the-middle attacks.',
          'Error: remote port forwarding failed for listen port 8080',
        ], 255),
        isA<SshRemotePortRefusedException>(),
      );
    });

    test("isn't a refused login for a banner that says so", () {
      expect(
        tunnelFailure([
          'Welcome! Permission denied (unless you are an admin).',
          'Error: remote port forwarding failed for listen port 8080',
        ], 255),
        isA<SshRemotePortRefusedException>(),
      );
    });

    test("isn't swayed by a banner's words", () {
      expect(
        tunnelFailure([
          'Idle sessions are timed out and disconnected after 15 minutes.',
          'Error: remote port forwarding failed for listen port 8080',
        ], 255),
        isA<SshRemotePortRefusedException>(),
      );
    });

    for (final banner in [
      'Notice: Connection closed by policy after 1 hour.',
      'We are unable to negotiate with legacy clients.',
    ]) {
      test('reads "$banner" as a banner', () {
        expect(
          tunnelFailure([
            banner,
            'Error: remote port forwarding failed for listen port 8080',
          ], 255),
          isA<SshRemotePortRefusedException>(),
        );
      });
    }

    for (final line in [
      'Error: remote port forwarding failed for listen port 8080',
      // Shared through a ControlMaster, from `ssh -O forward`.
      'mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 8080',
    ]) {
      test('names the server port refused in "$line"', () {
        expect(
          tunnelFailure(['debug1: Entering interactive session.', line], 255),
          isA<SshRemotePortRefusedException>()
              .having((exception) => exception.port, 'port', 8080)
              .having((exception) => exception.message, 'message', line)
              .having((exception) => exception.exitCode, 'exitCode', 255),
        );
      });
    }

    test('lets a refused login win over a refused server port', () {
      expect(
        tunnelFailure([
          'user@ssh.example.com: Permission denied (publickey).',
          'Error: remote port forwarding failed for listen port 8080',
        ], 255),
        isA<SshLoginRefusedException>(),
      );
    });

    test("ignores a forwarded connection's failure", () {
      expect(
        tunnelFailure([
          'channel 3: open failed: administratively prohibited: open failed',
          'Connection to ssh.example.com closed by remote host.',
        ], 255),
        isA<SshDroppedException>(),
      );
    });

    test('ignores ssh -v progress', () {
      expect(
        tunnelFailure([
          'debug1: Next authentication method: publickey',
          'debug1: Permission denied for one key, trying the next',
          'Connection to ssh.example.com closed by remote host.',
        ], 255),
        isA<SshDroppedException>(),
      );
    });

    test('says the exit code when ssh said nothing', () {
      final failure = tunnelFailure([], 255);

      expect(failure, isA<SshFailedException>());
      expect(failure.message, 'ssh exited with code 255');
    });
  });

  group('classify', () {
    test('says a forwarded connection the destination refused failed', () {
      const line = 'channel 2: open failed: connect failed: Connection refused';

      expect(
        classify(line),
        const SshForwardFailed(line, reason: 'Connection refused'),
      );
    });

    test('says one the server refused failed', () {
      const line =
          'channel 3: open failed: administratively prohibited: open failed';

      expect(
        classify(line),
        const SshForwardFailed(line, reason: 'administratively prohibited'),
      );
    });

    test('keeps -v progress about a channel as progress', () {
      const line = 'debug1: channel 3: open failed: connect failed: x';

      expect(classify(line), const SshProgress(line));
    });

    test('tells -v progress from anything else', () {
      expect(
        classify('debug1: channel 3: new [direct-tcpip]'),
        const SshProgress('debug1: channel 3: new [direct-tcpip]'),
      );
      expect(
        classify('Connection to ssh.example.com closed.'),
        const SshMessage('Connection to ssh.example.com closed.'),
      );
    });
  });

  test('isListeningOn matches only the port asked for', () {
    const line = 'debug1: Local forwarding listening on 127.0.0.1 port 5000.';

    expect(isListeningOn(line, 5000), isTrue);
    expect(isListeningOn(line, 500), isFalse);
    expect(isListeningOn(line, 50000), isFalse);
  });

  test('isListeningOn matches the port on any address', () {
    expect(
      isListeningOn(
        'debug1: Local forwarding listening on 172.17.0.1 port 5000.',
        5000,
      ),
      isTrue,
    );
    expect(
      isListeningOn(
          'debug1: Local forwarding listening on :: port 5000.', 5000),
      isTrue,
    );
  });
}
