import 'package:logging/logging.dart';

import 'ssh_log.dart';

final logger = Logger('system_ssh');

/// Hands [log] to an app's [onLog], which must not break ssh's output.
void reportTo(void Function(SshLog log)? onLog, SshLog log) {
  try {
    onLog?.call(log);
  } catch (exception, stackTrace) {
    logger.warning('onLog threw', exception, stackTrace);
  }
}
