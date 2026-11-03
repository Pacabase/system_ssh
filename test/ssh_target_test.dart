import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  group('equality', () {
    test('holds for the same host, port and user', () {
      const target = SshTarget('ssh.example.com', port: 2222, user: 'alice');
      final same = SshTarget('ssh.example.com', port: 2222, user: 'alice');

      expect(same, target);
      expect(same.hashCode, target.hashCode);
    });

    test('holds for a bare host', () {
      expect(SshTarget('ssh.example.com'), const SshTarget('ssh.example.com'));
    });

    for (final (name, other) in [
      ('host', const SshTarget('other.example.com', port: 2222, user: 'alice')),
      ('port', const SshTarget('ssh.example.com', port: 22, user: 'alice')),
      ('missing port', const SshTarget('ssh.example.com', user: 'alice')),
      ('user', const SshTarget('ssh.example.com', port: 2222, user: 'bob')),
      ('missing user', const SshTarget('ssh.example.com', port: 2222)),
    ]) {
      test('fails on a different $name', () {
        expect(
          other,
          isNot(const SshTarget('ssh.example.com', port: 2222, user: 'alice')),
        );
      });
    }

    test('fails against another type', () {
      expect(const SshTarget('ssh.example.com'), isNot('ssh.example.com'));
    });
  });

  group('toString', () {
    test('is user@host:port', () {
      expect(
        const SshTarget(
          'ssh.example.com',
          port: 2222,
          user: 'alice',
        ).toString(),
        'SshTarget(alice@ssh.example.com:2222)',
      );
    });

    test('is just the host when port and user are unset', () {
      expect(
        const SshTarget('ssh.example.com').toString(),
        'SshTarget(ssh.example.com)',
      );
    });

    test('leaves out an unset user', () {
      expect(
        const SshTarget('ssh.example.com', port: 2222).toString(),
        'SshTarget(ssh.example.com:2222)',
      );
    });

    test('leaves out an unset port', () {
      expect(
        const SshTarget('ssh.example.com', user: 'alice').toString(),
        'SshTarget(alice@ssh.example.com)',
      );
    });

    test('brackets an IPv6 host when it shows the port', () {
      expect(
        const SshTarget('::1', port: 22).toString(),
        'SshTarget([::1]:22)',
      );
    });

    test('brackets an IPv6 host after the user', () {
      expect(
        const SshTarget('fd00::5', port: 2222, user: 'alice').toString(),
        'SshTarget(alice@[fd00::5]:2222)',
      );
    });

    test('leaves an IPv6 host bare without a port', () {
      expect(
        const SshTarget('::1', user: 'alice').toString(),
        'SshTarget(alice@::1)',
      );
    });
  });
}
