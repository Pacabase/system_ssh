import 'dart:io';

import 'package:system_ssh/src/login_shell.dart';
import 'package:test/test.dart';

import 'fakes/fakes.dart';

void main() {
  test(
    'loginShellEnvironment is empty on Windows',
    skip: Platform.isWindows ? null : 'Windows only',
    () async {
      expect(await loginShellEnvironment(), isEmpty);
    },
  );

  group(
    'shellEnvironment',
    skip: Platform.isWindows ? 'needs a POSIX shell' : null,
    () {
      late Directory directory;

      setUp(() {
        directory = Directory.systemTemp.createTempSync('login_shell');
        addTearDown(() => deleteSoon(directory));
      });

      /// A shell that runs [body], where `$4` is the command it was given.
      Future<String> fakeShell(String body) async {
        final shell = File('${directory.path}/shell')
          ..writeAsStringSync('#!/bin/sh\n$body\n');
        await Process.run('chmod', ['+x', shell.path]);
        return shell.path;
      }

      Future<Map<String, String>> read(
        String shell, {
        Duration timeout = const Duration(seconds: 10),
      }) =>
          shellEnvironment(shell, timeout: timeout);

      test('reads the kept variables, ignoring what rc files print', () async {
        final shell = await fakeShell(r'''
[ "$1 $2 $3" = '-l -i -c' ] || exit 9
echo 'Last login: today'
printf '\033]0;title\007%%\n'
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin HOME=/home/alice \
  SSH_AUTH_SOCK=/tmp/agent.sock SHLVL=2 EDITOR=vim sh -c "$4"
echo 'bye'
''');

        expect(await read(shell), {
          'PATH': '/opt/homebrew/bin:/usr/bin:/bin',
          'HOME': '/home/alice',
          'SSH_AUTH_SOCK': '/tmp/agent.sock',
        });
      });

      test('keeps values holding newlines and =', () async {
        final shell = await fakeShell(r'''
env -i PATH=/usr/bin:/bin DISPLAY=:0 SSH_ASKPASS_REQUIRE=force \
  "SSH_NOTE=one
two=three" sh -c "$4"
''');

        expect(await read(shell), {
          'PATH': '/usr/bin:/bin',
          'DISPLAY': ':0',
          'SSH_ASKPASS_REQUIRE': 'force',
          'SSH_NOTE': 'one\ntwo=three',
        });
      });

      test('is empty when the shell exits non-zero', () async {
        final shell = await fakeShell(r'''
env -i PATH=/usr/bin:/bin sh -c "$4"
exit 1
''');

        expect(await read(shell), isEmpty);
      });

      test('is empty when the shell prints no markers', () async {
        final shell = await fakeShell("echo 'PATH=/usr/bin'");

        expect(await read(shell), isEmpty);
      });

      test('is empty when the shell does not exist', () async {
        expect(await read('${directory.path}/nonexistent'), isEmpty);
      });

      test('is empty in time for a hanging shell, and stops it', () async {
        final pids = File('${directory.path}/pids');
        final shell = await fakeShell('''
echo \$\$ > ${pids.path}
sleep 60 &
echo \$! >> ${pids.path}
wait
''');
        final stopwatch = Stopwatch()..start();

        expect(await read(shell, timeout: const Duration(seconds: 1)), isEmpty);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
        final started = await eventually(() {
          final lines =
              pids.existsSync() ? pids.readAsLinesSync() : const <String>[];
          return lines.length == 2 ? lines.map(int.parse).toList() : null;
        });
        for (final pid in started) {
          expect(await stops(pid), isTrue);
        }
      });
    },
  );

  group('parseShellEnvironment', () {
    const marker = 'system_ssh_0123456789abcdef';

    test('reads NUL-separated variables between the markers', () {
      expect(
        parseShellEnvironment(
          'junk${marker}PATH=/bin\x00HOME=/home/alice\x00${marker}junk',
          marker,
        ),
        {'PATH': '/bin', 'HOME': '/home/alice'},
      );
    });

    test('keeps PATH, HOME, DISPLAY and SSH_ variables only', () {
      expect(
        parseShellEnvironment(
          '${marker}PATH=/bin\x00SHLVL=2\x00PWD=/\x00_=/usr/bin/env\x00'
          'DISPLAY=:0\x00SSH_AUTH_SOCK=/tmp/agent.sock\x00SSH_ASKPASS=/a\x00'
          'SSH=no\x00path=/lower\x00$marker',
          marker,
        ),
        {
          'PATH': '/bin',
          'DISPLAY': ':0',
          'SSH_AUTH_SOCK': '/tmp/agent.sock',
          'SSH_ASKPASS': '/a',
        },
      );
    });

    test('keeps an empty value', () {
      expect(
        parseShellEnvironment('${marker}SSH_AUTH_SOCK=\x00$marker', marker),
        {'SSH_AUTH_SOCK': ''},
      );
    });

    for (final (name, output) in [
      ('no output', ''),
      ('no markers', 'PATH=/bin\x00'),
      ('one marker', '${marker}PATH=/bin\x00'),
      ('nothing between the markers', '$marker$marker'),
      ('no closing NUL', '${marker}PATH=/bin$marker'),
      ('an entry without =', '${marker}PATH=/bin\x00junk\x00$marker'),
      ('an entry without a name', '$marker=value\x00$marker'),
    ]) {
      test('is empty for $name', () {
        expect(parseShellEnvironment(output, marker), isEmpty);
      });
    }
  });

  test('reads the login shell once per process', () {
    expect(
      identical(cachedLoginShellEnvironment(), cachedLoginShellEnvironment()),
      isTrue,
    );
  });
}
