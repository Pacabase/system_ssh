import 'dart:math';

final _progress = RegExp(
  r'^(debug\d|OpenSSH_|Authenticated to |Transferred: |Bytes per second: |Warning: Permanently added )',
);

bool isProgress(String line) => _progress.hasMatch(line);

String failureMessage(List<String> log) {
  final lines = log.where((line) => line.trim().isNotEmpty).toList();
  final errors = lines.where((line) => !isProgress(line)).toList();
  final reason =
      errors.isNotEmpty ? errors : lines.sublist(max(0, lines.length - 3));

  return reason.join('\n');
}
