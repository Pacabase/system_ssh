import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  group('tunnelCommand', () {
    test('forwards the local port through the server', () {
      expect(
        tunnelCommand(
          const SshTarget('ssh.example.com'),
          remoteHost: 'db.example.com',
          remotePort: 5432,
          localPort: 15432,
        ),
        'ssh -N -L 127.0.0.1:15432:db.example.com:5432 ssh.example.com',
      );
    });

    test('names the user and port, and brackets an IPv6 destination', () {
      expect(
        tunnelCommand(
          const SshTarget('ssh.example.com', user: 'deploy', port: 2222),
          remoteHost: 'fd00::5',
          remotePort: 5432,
          localPort: 15432,
        ),
        'ssh -N -L 127.0.0.1:15432:[fd00::5]:5432 -p 2222 '
        'deploy@ssh.example.com',
      );
    });

    test('quotes what a shell would split or expand', () {
      expect(
        tunnelCommand(
          const SshTarget("my server's alias"),
          remoteHost: 'db.example.com',
          remotePort: 5432,
          localPort: 15432,
        ),
        'ssh -N -L 127.0.0.1:15432:db.example.com:5432 '
        "'my server'\\''s alias'",
      );
    });

    test('rejects a host ssh would read as an option', () {
      expect(
        () => tunnelCommand(
          const SshTarget('-oProxyCommand=false'),
          remoteHost: 'db.example.com',
          remotePort: 5432,
          localPort: 15432,
        ),
        throwsArgumentError,
      );
    });
  });

  test('socksProxyCommand serves a SOCKS proxy through the server', () {
    expect(
      socksProxyCommand(const SshTarget('ssh.example.com'), localPort: 1080),
      'ssh -N -D 127.0.0.1:1080 ssh.example.com',
    );
  });
}
