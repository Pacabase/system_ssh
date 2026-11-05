import 'dart:math';

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
