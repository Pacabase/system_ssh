import 'dart:io';

import 'package:system_ssh/src/config_hosts.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late String ssh;

  setUp(() {
    home = Directory.systemTemp.createTempSync('system_ssh_hosts');
    ssh = '${home.path}/.ssh';
    Directory(ssh).createSync();
  });

  tearDown(() => home.deleteSync(recursive: true));

  void write(String name, String content) =>
      (File('$ssh/$name')..parent.createSync(recursive: true))
          .writeAsStringSync(content);

  Future<List<String>> hosts() =>
      readConfigHosts('$ssh/config', sshDirectory: ssh);

  test('lists every alias once, in the order the config names them', () async {
    write('config', '''
Host dev staging
  HostName 10.0.0.1
Host prod
Host dev
''');

    expect(await hosts(), ['dev', 'staging', 'prod']);
  });

  test('leaves out patterns and negations', () async {
    write('config', '''
Host *
Host *.internal web? !bastion db
''');

    expect(await hosts(), ['db']);
  });

  test('reads keywords in any case, with = and quotes, past comments',
      () async {
    write('config', '''
# Host commented
HOST upper
host=equals
  Host   "quoted"   spaced
Match host other
  User me
''');

    expect(await hosts(), ['upper', 'equals', 'quoted', 'spaced']);
  });

  test('follows Include from ~/.ssh, by path, ~ and glob, in order', () async {
    write('config', '''
Host first
Include config.d/*
Include ~/.ssh/extra
Include ${home.path}/absolute
Host last
''');
    write('config.d/b', 'Host from-b');
    write('config.d/a', 'Host from-a');
    write('extra', 'Host from-tilde');
    File('${home.path}/absolute').writeAsStringSync('Host from-absolute');

    expect(await hosts(), [
      'first',
      'from-a',
      'from-b',
      'from-tilde',
      'from-absolute',
      'last',
    ]);
  });

  test('reads a file that includes itself only once', () async {
    write('config', 'Host one\nInclude other');
    write('other', 'Host two\nInclude config');

    expect(await hosts(), ['one', 'two']);
  });

  test('is empty without a config, and skips includes that are missing',
      () async {
    expect(await hosts(), isEmpty);

    write('config', 'Include missing\nInclude nothing/*\nHost kept');

    expect(await hosts(), ['kept']);
  });

  test('SystemSshClient reads the config in its HOME', () async {
    write('config', 'Host dev');

    expect(
      await SystemSshClient(environment: {'HOME': home.path}).configuredHosts(),
      ['dev'],
    );
  });
}
