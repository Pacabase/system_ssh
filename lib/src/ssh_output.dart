import 'dart:math';

import 'exceptions.dart';
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

/// ssh's exit with [code], saying why from [log].
SshTunnelException tunnelFailure(List<String> log, int code) {
  final reason = failureMessage(log);
  return SshTunnelException(
    reason.isEmpty ? 'ssh exited with code $code' : reason,
    log: List.unmodifiable(log),
    exitCode: code,
    isPermanent: isPermanentFailure(log),
  );
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

/// A shared master is up once it listens for `-O` commands and has started
/// its session.
final class MasterReadiness implements ForwardReadiness {
  bool _isMultiplexing = false;
  bool _isSessionStarted = false;

  @override
  bool isReadyAfter(String line) {
    if (line.contains('setting up multiplex master socket')) {
      _isMultiplexing = true;
    }
    if (isSessionStarted(line)) _isSessionStarted = true;
    return _isMultiplexing && _isSessionStarted;
  }
}

/// A master's own lines about the `-O` commands it serves, which the commands
/// already report, such as a bind failure for a taken port.
bool isMuxChatter(String line) => _muxChatter.hasMatch(line);

final _muxChatter =
    RegExp(r'^(mux_|bind \[|channel_setup_fwd_listener|Could not request )');

// "connect_to localhost port 3000: failed.", for a remote forward.
final _localConnectFailed = RegExp(r'^connect_to (\S+) port (\d+): failed');

/// The host and port of a remote forward's destination that couldn't be
/// reached, or null for another line.
String? failedDestination(String line) =>
    switch (_localConnectFailed.firstMatch(line)) {
      final match? => '${match[1]}:${match[2]}',
      null => null,
    };

// "channel 1: open failed: connect failed: Connection refused"
final _channelFailed = RegExp(r'^channel (\d+): open failed: ');

// "debug1: channel 1: free: direct-tcpip: listening port 42303 for 127.0.0.1
// port 1, connect from 127.0.0.1 port 56239 to 127.0.0.1 port 42303, ..."
final _channelFreed = RegExp(r'channel (\d+): free: (.*)$');
// The type can be `direct-streamlocal@openssh.com`, for a socket forward.
final _listeningPort = RegExp(r'^(?:[\w@.-]+: )?listening port (\d+) ');

/// The channel a failed connection was on, or null for another line.
int? failedChannel(String line) =>
    int.tryParse(_channelFailed.firstMatch(line)?[1] ?? '');

/// The channel ssh freed, with the local port it was forwarded from when it
/// says, or null for another line.
(int, int?)? freedChannel(String line) =>
    switch (_channelFreed.firstMatch(line)) {
      final match? => (
          int.parse(match[1]!),
          int.tryParse(_listeningPort.firstMatch(match[2]!)?[1] ?? ''),
        ),
      null => null,
    };
