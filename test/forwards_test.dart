import 'package:system_ssh/src/forwards.dart';
import 'package:test/test.dart';

void main() {
  group('a forward equals another', () {
    test('of the same kind with the same fields', () {
      expect(
        const LocalForward(50000, remoteHost: 'db', remotePort: 5432),
        const LocalForward(50000, remoteHost: 'db', remotePort: 5432),
      );
      expect(
        const SocketForward(50000, remoteSocket: '/run/d.sock'),
        const SocketForward(50000, remoteSocket: '/run/d.sock'),
      );
      expect(const DynamicForward(1080), const DynamicForward(1080));
      expect(
        const RemoteForward(8080, localHost: 'localhost', localPort: 3000),
        const RemoteForward(8080, localHost: 'localhost', localPort: 3000),
      );
      expect(
        const RemoteForward(
          8080,
          localHost: 'localhost',
          localPort: 3000,
        ).hashCode,
        const RemoteForward(
          8080,
          localHost: 'localhost',
          localPort: 3000,
        ).hashCode,
      );
    });

    test('to an IPv6 host with or without brackets', () {
      const bare = RemoteForward(8080, localHost: '::1', localPort: 3000);
      const bracketed = RemoteForward(
        8080,
        localHost: '[::1]',
        localPort: 3000,
      );
      expect(bare, bracketed);
      expect(bare.hashCode, bracketed.hashCode);
      expect(bare.arguments, bracketed.arguments);
      expect(
        const LocalForward(50000, remoteHost: '::1', remotePort: 3000),
        const LocalForward(50000, remoteHost: '[::1]', remotePort: 3000),
      );
    });
  });

  group('a forward differs from another', () {
    test('on another port, address or destination', () {
      const forward = LocalForward(50000, remoteHost: 'db', remotePort: 5432);
      expect(
        forward,
        isNot(const LocalForward(50001, remoteHost: 'db', remotePort: 5432)),
      );
      expect(
        forward,
        isNot(
          const LocalForward(
            50000,
            bindAddress: '0.0.0.0',
            remoteHost: 'db',
            remotePort: 5432,
          ),
        ),
      );
      expect(
        forward,
        isNot(const LocalForward(50000, remoteHost: 'db2', remotePort: 5432)),
      );
      expect(
        const RemoteForward(8080, localHost: 'localhost', localPort: 3000),
        isNot(const RemoteForward(0, localHost: 'localhost', localPort: 3000)),
      );
    });

    test('of another kind with the same ports', () {
      expect(
        const DynamicForward(1080),
        isNot(const SocketForward(1080, remoteSocket: '/run/d.sock')),
      );
      expect(
        const LocalForward(3000, remoteHost: 'localhost', remotePort: 3000),
        isNot(
          const RemoteForward(3000, localHost: 'localhost', localPort: 3000),
        ),
      );
    });
  });

  test('a remote forward connects to its host without brackets', () {
    expect(
      const RemoteForward(0, localHost: '[::1]', localPort: 3000).destination,
      (host: '::1', port: 3000),
    );
  });

  test('describes a forward as ssh reads it', () {
    const forward = LocalForward(50000, remoteHost: 'db', remotePort: 5432);
    expect(forward.description, '127.0.0.1:50000:db:5432');
    expect('$forward', '-L 127.0.0.1:50000:db:5432');
  });
}
