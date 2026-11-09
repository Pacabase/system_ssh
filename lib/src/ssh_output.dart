import 'dart:math';

import 'ssh_log.dart';

final _progress = RegExp(
  r'^(debug\d|OpenSSH_|Authenticated to |Transferred: |Bytes per second: |Warning: Permanently added |Allocated port \d+ for remote forward )',
);

// What ssh says when only a change to keys, config or the server can help.
final _permanent = RegExp(
  'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|'
  r'Permission denied \(|Too many authentication failures|'
  'bad configuration option|Bad owner or permissions|'
  'no argument after keyword|garbage at end of line',
  caseSensitive: false,
);

bool isProgress(String line) => _progress.hasMatch(line);

bool isPermanentFailure(List<String> log) =>
    log.where((line) => !isProgress(line)).any(_permanent.hasMatch);

String failureMessage(List<String> log) {
  final lines = log.where((line) => line.trim().isNotEmpty).toList();
  final errors = lines.where((line) => !isProgress(line)).toList();
  final reason =
      errors.isNotEmpty ? errors : lines.sublist(max(0, lines.length - 3));

  return reason.join('\n');
}

/// Whether [line] is ssh saying it set up the forward on [localPort]; ssh logs
/// this before it binds, so only a started session after it means ready.
bool isListeningOn(String line, int localPort) =>
    _listening.firstMatch(line)?[1] == '$localPort';

final _listening =
    RegExp(r'Local forwarding listening on 127\.0\.0\.1 port (\d+)\b');

bool isSessionStarted(String line) =>
    line.contains('Entering interactive session');

/// Reads what ssh writes while it connects, to tell when its forward is up.
abstract interface class ForwardReadiness {
  /// Takes ssh's next line; true once the forward is up.
  bool isReadyAfter(String line);
}

final class LocalForwardReadiness implements ForwardReadiness {
  LocalForwardReadiness(this.port);

  final int port;
  bool _isListening = false;

  @override
  bool isReadyAfter(String line) {
    if (isListeningOn(line, port)) _isListening = true;
    return _isListening && isSessionStarted(line);
  }
}

// "debug1: remote forward success for: listen 127.0.0.1:8080, connect localhost:3000"
final _remoteForwarded =
    RegExp(r'remote forward success for: listen 127\.0\.0\.1:(\d+),');

// "Allocated port 41234 for remote forward to localhost:3000"
final _allocated = RegExp(r'^Allocated port (\d+) for remote forward to (.+)$');

/// A remote forward is up once the server accepts it. ssh can enter the
/// session before the server answers, so the two may come in either order.
final class RemoteForwardReadiness implements ForwardReadiness {
  /// For a forward of [requestedPort] on the server, or a port the server
  /// picks when it is 0, to [localHost]:[localPort].
  RemoteForwardReadiness(
    this.requestedPort, {
    required String localHost,
    required int localPort,
  }) : _destination = '$localHost:$localPort';

  final int requestedPort;
  final String _destination;
  bool _isSessionStarted = false;

  /// The server's port, once it has accepted the forward.
  int? port;

  @override
  bool isReadyAfter(String line) {
    if (isSessionStarted(line)) _isSessionStarted = true;
    if (requestedPort == 0) {
      if (_allocated.firstMatch(line) case final match?
          when match[2] == _destination) {
        port = int.parse(match[1]!);
      }
    } else if (_remoteForwarded.firstMatch(line)?[1] == '$requestedPort') {
      port = requestedPort;
    }
    return _isSessionStarted && port != null;
  }
}

// "channel 2: open failed: connect failed: Connection refused", or
// "channel 3: open failed: administratively prohibited: open failed".
final _refused = RegExp(
  r'^channel \d+: open failed: (?:connect failed: )?(.+?)(?:: open failed)?$',
);

SshLog classify(String line) {
  if (isProgress(line)) return SshProgress(line);
  if (_refused.firstMatch(line)?[1] case final reason?) {
    return SshForwardFailed(line, reason: reason);
  }
  return SshMessage(line);
}
