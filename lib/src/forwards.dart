import 'ssh_command.dart';

sealed class Forward {
  const Forward();

  List<String> get arguments;

  /// What it forwards, for messages: `127.0.0.1:50000:db.example.com:3306`.
  String get description => arguments.last;

  @override
  String toString() => arguments.join(' ');

  // The arguments bracket an IPv6 host, so `::1` and `[::1]` are equal.
  @override
  bool operator ==(Object other) =>
      other is Forward &&
      other.runtimeType == runtimeType &&
      other.toString() == toString();

  @override
  int get hashCode => Object.hash(runtimeType, toString());
}

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
  List<String> get arguments => [
    '-L',
    '$_listen:${bracketIPv6(remoteHost)}:$remotePort',
  ];
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
}

final class DynamicForward extends ListeningForward {
  const DynamicForward(super.localPort, {super.bindAddress = '127.0.0.1'});

  @override
  List<String> get arguments => ['-D', _listen];
}

typedef LocalDestination = ({String host, int port});

/// A [remotePort] of 0 has the server pick one.
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
}

/// ssh reads `::1` and `[::1]` as the same host.
String _unbracketed(String host) => host.startsWith('[') && host.endsWith(']')
    ? host.substring(1, host.length - 1)
    : host;
