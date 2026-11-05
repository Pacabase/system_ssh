import 'dart:io';

// ssh gives up on Include nested deeper than this.
const _maxDepth = 16;

final _keyword = RegExp(r'^(\S+?)(?:\s*=\s*|\s+)(.*)$');
final _argument = RegExp(r'"([^"]*)"|(\S+)');
final _pattern = RegExp(r'[*?!]');

Future<List<String>> readConfigHosts(
  String path, {
  required String sshDirectory,
}) async {
  final hosts = <String>{};
  await _read(File(path), sshDirectory, hosts, depth: 0, seen: {});
  return hosts.toList();
}

Future<void> _read(
  File file,
  String sshDirectory,
  Set<String> hosts, {
  required int depth,
  required Set<String> seen,
}) async {
  if (depth > _maxDepth || !seen.add(file.absolute.path)) return;

  final List<String> lines;
  try {
    lines = await file.readAsLines();
  } on FileSystemException {
    return;
  }

  for (final line in lines.map((line) => line.trim())) {
    if (line.startsWith('#')) continue;
    final match = _keyword.firstMatch(line);
    if (match == null) continue;

    final arguments = [
      for (final argument in _argument.allMatches(match[2]!))
        argument[1] ?? argument[2]!,
    ];
    switch (match[1]!.toLowerCase()) {
      case 'host':
        hosts.addAll(arguments.where((host) => !host.contains(_pattern)));
      case 'include':
        for (final included in arguments.expand(
          (argument) => _expand(argument, sshDirectory),
        )) {
          await _read(
            included,
            sshDirectory,
            hosts,
            depth: depth + 1,
            seen: seen,
          );
        }
    }
  }
}

// An Include names files the way a shell glob does, from ~/.ssh when relative.
List<File> _expand(String argument, String sshDirectory) {
  final home = Directory(sshDirectory).parent.path;
  final named = switch (argument) {
    '~' => home,
    _ when argument.startsWith('~/') => '$home${argument.substring(1)}',
    _ when File(argument).isAbsolute => argument,
    _ => '$sshDirectory/$argument',
  };
  final path = named.replaceAll(r'\', '/');
  if (!path.contains(RegExp('[*?]'))) return [File(path)];

  var matches = [path.startsWith('/') ? '/' : ''];
  for (final segment in path.split('/').where((part) => part.isNotEmpty)) {
    matches = [
      for (final parent in matches)
        if (!segment.contains(RegExp('[*?]')))
          '$parent${parent.endsWith('/') || parent.isEmpty ? '' : '/'}$segment'
        else
          ..._matching(parent, segment),
    ];
  }

  return [
    for (final match in matches..sort())
      if (FileSystemEntity.isFileSync(match)) File(match),
  ];
}

List<String> _matching(String parent, String segment) {
  final name = RegExp(
    '^${RegExp.escape(segment).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$',
  );
  try {
    return [
      for (final entity in Directory(parent.isEmpty ? '.' : parent).listSync())
        if (name.hasMatch(
            entity.uri.pathSegments.lastWhere((part) => part.isNotEmpty)))
          entity.path,
    ];
  } on FileSystemException {
    return const [];
  }
}
