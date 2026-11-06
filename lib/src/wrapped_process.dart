import 'dart:io';

/// A [Process] that passes everything through to [process], leaving [kill] to
/// each platform.
abstract base class WrappedProcess implements Process {
  WrappedProcess(this.process);

  final Process process;

  @override
  int get pid => process.pid;

  @override
  IOSink get stdin => process.stdin;

  @override
  Stream<List<int>> get stdout => process.stdout;

  @override
  Stream<List<int>> get stderr => process.stderr;

  @override
  Future<int> get exitCode => process.exitCode;
}
