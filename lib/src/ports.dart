import 'dart:io';

import 'exceptions.dart';

// EADDRNOTAVAIL on macOS, Linux and Windows.
const _notHere = {49, 99, 10049};

/// Whether [port] on [address] is free. Throws an [SshException] when
/// [address] isn't one this computer has.
Future<bool> isPortFree(int port, {String address = '127.0.0.1'}) async {
  try {
    await (await _bind(address, port)).close();
    return true;
  } on SocketException catch (exception) {
    _throwIfNotHere(address, exception);
    return false;
  }
}

/// A port on [address] that was free a moment ago.
Future<int> pickFreePort({String address = '127.0.0.1'}) async {
  final ServerSocket server;
  try {
    server = await _bind(address, 0);
  } on SocketException catch (exception) {
    _throwIfNotHere(address, exception);
    rethrow;
  }
  final port = server.port;
  await server.close();
  return port;
}

// ssh listens on an IPv6 address alone, so `::` mustn't take IPv4 too.
Future<ServerSocket> _bind(String address, int port) =>
    ServerSocket.bind(InternetAddress(address), port, v6Only: true);

void _throwIfNotHere(String address, SocketException exception) {
  if (_notHere.contains(exception.osError?.errorCode)) {
    throw SshException("$address isn't an address of this computer");
  }
}
