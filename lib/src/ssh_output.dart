import 'dart:math';

import 'ssh_log.dart';

final _progress = RegExp(
  r'^(debug\d|OpenSSH_|Authenticated to |Transferred: |Bytes per second: |Warning: Permanently added )',
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
