import 'dart:io';

Future<bool> isPortFree(int port) async {
  try {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await server.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// A `127.0.0.1` port that was free a moment ago.
Future<int> pickFreePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}
