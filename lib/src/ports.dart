import 'dart:io';

import 'exceptions.dart';

// EADDRNOTAVAIL on macOS, Linux and Windows.
const _notHere = {49, 99, 10049};

/// Whether [port] on [address] is free. Throws an [SshException] when
/// [address] isn't one of this computer's.
Future<bool> isPortFree(int port, {String address = '127.0.0.1'}) async {
  try {
    final server = await ServerSocket.bind(address, port);
    await server.close();
    return true;
  } on SocketException catch (exception) {
    if (_notHere.contains(exception.osError?.errorCode)) {
      throw _notAnAddressHere(address);
    }
    return false;
  }
}

/// A port on [address] that was free a moment ago.
Future<int> pickFreePort({String address = '127.0.0.1'}) async {
  final ServerSocket server;
  try {
    server = await ServerSocket.bind(address, 0);
  } on SocketException catch (exception) {
    if (_notHere.contains(exception.osError?.errorCode)) {
      throw _notAnAddressHere(address);
    }
    rethrow;
  }
  final port = server.port;
  await server.close();
  return port;
}

SshException _notAnAddressHere(String address) =>
    SshException("$address isn't an address of this computer");
