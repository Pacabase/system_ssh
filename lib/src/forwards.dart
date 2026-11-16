import 'ssh_command.dart';

/// One forward ssh serves: `-L` to a host and port or a socket, `-D`, or
/// `-R`.
sealed class Forward {
  const Forward();

  /// The ssh arguments that ask for it, such as
  /// `-L 127.0.0.1:50000:db.example.com:3306`.
  List<String> get arguments;

  /// What it forwards, for messages: `127.0.0.1:50000:db.example.com:3306`.
  String get description => arguments.last;

  @override
  String toString() => arguments.join(' ');
}

/// A forward that listens on this computer: `-L` or `-D`.
sealed class ListeningForward extends Forward {
  const ListeningForward(this.localPort, {required this.bindAddress});

  final int localPort;
  final String bindAddress;

  String get _listen => '${bracketIPv6(bindAddress)}:$localPort';
}

final class LocalForward extends ListeningForward {
  const LocalForward(
    super.localPort, {
    super.bindAddress = '127.0.0.1',
    required this.remoteHost,
    required this.remotePort,
  });

  final String remoteHost;
  final int remotePort;

  @override
  List<String> get arguments =>
      ['-L', '$_listen:${bracketIPv6(remoteHost)}:$remotePort'];

  @override
  bool operator ==(Object other) =>
      other is LocalForward &&
      other.localPort == localPort &&
      other.bindAddress == bindAddress &&
      _unbracketed(other.remoteHost) == _unbracketed(remoteHost) &&
      other.remotePort == remotePort;

  @override
  int get hashCode => Object.hash(
        LocalForward,
        localPort,
        bindAddress,
        _unbracketed(remoteHost),
        remotePort,
      );
}

final class SocketForward extends ListeningForward {
  const SocketForward(
    super.localPort, {
    super.bindAddress = '127.0.0.1',
    required this.remoteSocket,
  });

  final String remoteSocket;

  @override
  List<String> get arguments => ['-L', '$_listen:$remoteSocket'];

  @override
  bool operator ==(Object other) =>
      other is SocketForward &&
      other.localPort == localPort &&
      other.bindAddress == bindAddress &&
      other.remoteSocket == remoteSocket;

  @override
  int get hashCode =>
      Object.hash(SocketForward, localPort, bindAddress, remoteSocket);
}

final class DynamicForward extends ListeningForward {
  const DynamicForward(super.localPort, {super.bindAddress = '127.0.0.1'});

  @override
  List<String> get arguments => ['-D', _listen];

  @override
  bool operator ==(Object other) =>
      other is DynamicForward &&
      other.localPort == localPort &&
      other.bindAddress == bindAddress;

  @override
  int get hashCode => Object.hash(DynamicForward, localPort, bindAddress);
}

/// A host and port on this computer that a remote forward connects to.
typedef LocalDestination = ({String host, int port});

/// A forward from the server's `127.0.0.1:`[remotePort] to [localHost] and
/// [localPort] here. A [remotePort] of 0 has the server pick one.
final class RemoteForward extends Forward {
  const RemoteForward(
    this.remotePort, {
    required this.localHost,
    required this.localPort,
  });

  final int remotePort;
  final String localHost;
  final int localPort;

  @override
  List<String> get arguments => [
        '-R',
        '127.0.0.1:$remotePort:${bracketIPv6(localHost)}:$localPort',
      ];

  /// Where it connects, as ssh names it when that fails: without brackets
  /// around an IPv6 address.
  LocalDestination get destination =>
      (host: _unbracketed(localHost), port: localPort);

  @override
  bool operator ==(Object other) =>
      other is RemoteForward &&
      other.remotePort == remotePort &&
      other.destination == destination;

  @override
  int get hashCode => Object.hash(RemoteForward, remotePort, destination);
}

/// ssh reads `::1` and `[::1]` as the same host.
String _unbracketed(String host) => host.startsWith('[') && host.endsWith(']')
    ? host.substring(1, host.length - 1)
    : host;
