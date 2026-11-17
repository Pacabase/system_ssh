import 'dart:math';

import 'exceptions.dart';
import 'forwards.dart';
import 'ssh_log.dart';

final _progress = RegExp(
  r'^(debug\d|OpenSSH_|Authenticated to |Transferred: |Bytes per second: |Warning: Permanently added |Allocated port \d+ for remote forward )',
);

bool isProgress(String line) => _progress.hasMatch(line);

String failureMessage(List<String> log) {
  final lines = log.where((line) => line.trim().isNotEmpty).toList();
  final errors = lines.where((line) => !isProgress(line)).toList();
  final reason =
      errors.isNotEmpty ? errors : lines.sublist(max(0, lines.length - 3));

  return reason.join('\n');
}

typedef _Failure = SshException Function(
  String message, {
  List<String> log,
  int? exitCode,
});

// In the order to check them: a key, login or config at fault wins over the
// network error ssh may print after it. A server's banner can say anything,
// so what a banner could also say is matched on ssh's own wording only. A
// changed host key alone is a warning: ssh says it failed only when it stops.
final _failures = <(RegExp, _Failure)>[
  (_anyOf(['Host key verification failed']), SshHostKeyRefusedException.new),
  (
    RegExp(
      r'^(\S+: )?Permission denied \(|Too many authentication failures',
    ),
    SshLoginRefusedException.new,
  ),
  (
    _anyOf([
      'bad configuration option',
      'Bad owner or permissions',
      'no argument after keyword',
      'garbage at end of line',
    ]),
    SshConfigException.new,
  ),
  (RegExp('^Unable to negotiate with '), SshConfigException.new),
  (_anyOf(['Could not resolve hostname']), SshHostNotFoundException.new),
  (
    RegExp(
      r'^(ssh: )?connect to host .* port \d+: |'
      '^(kex|ssh)_exchange_identification: |'
      '^Connection timed out during banner exchange',
    ),
    SshUnreachableException.new,
  ),
  (
    RegExp(
      r'^([a-z_]+: )*(send disconnect: )?Connection (reset|closed) by |'
      '^Connection to .* closed by remote host|'
      r'^(\w+: )?Connection to .* port \d+: |'
      r'^Timeout, server .* not responding|: Broken pipe$',
    ),
    SshDroppedException.new,
  ),
];

RegExp _anyOf(List<String> phrases) =>
    RegExp(phrases.map(RegExp.escape).join('|'), caseSensitive: false);

/// ssh's exit with [code], as the class its lines in [log] say. A forwarded
/// connection's failure is about its destination, not why ssh exited.
SshException tunnelFailure(List<String> log, int code) {
  final reason = failureMessage(log);
  final errors = log.where((line) => classify(line) is SshMessage).toList();
  final message = reason.isEmpty ? 'ssh exited with code $code' : reason;
  final failure =
      _failures.where((each) => errors.any(each.$1.hasMatch)).firstOrNull?.$2;
  if (failure != null) {
    return failure(message, log: List.unmodifiable(log), exitCode: code);
  }
  final refusedPort = errors
      .map((line) => _remotePortRefused.firstMatch(line)?[2])
      .nonNulls
      .firstOrNull;
  if (refusedPort != null) {
    return SshRemotePortRefusedException(
      message,
      port: int.parse(refusedPort),
      log: List.unmodifiable(log),
      exitCode: code,
    );
  }
  return SshFailedException(
    message,
    log: List.unmodifiable(log),
    exitCode: code,
  );
}

// Checked last, so a key, login or config at fault still wins. ssh writes it
// after "Error: ", and `-O forward` after its own words.
final _remotePortRefused = RegExp(
  r'^(Error|mux_client_forward: forwarding request failed): '
  r'remote port forwarding failed for listen port (\d+)$',
);

/// Whether [line] is ssh saying it set up the forward on [localPort]; ssh logs
/// this before it binds, so only a started session after it means ready.
bool isListeningOn(String line, int localPort) =>
    _listening.firstMatch(line)?[1] == '$localPort';

final _listening = RegExp(r'Local forwarding listening on \S+ port (\d+)\b');

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
  /// For [forward], on the port it asks the server for, or the one the
  /// server picks when that is 0.
  RemoteForwardReadiness(RemoteForward forward)
      : requestedPort = forward.remotePort,
        _destination =
            '${forward.destination.host}:${forward.destination.port}';

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
LocalDestination? failedDestination(String line) =>
    switch (_localConnectFailed.firstMatch(line)) {
      final match? => (host: match[1]!, port: int.parse(match[2]!)),
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
