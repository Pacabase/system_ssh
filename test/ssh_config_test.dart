import 'dart:async';

import 'package:system_ssh/src/ssh_config.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';
import 'fakes/fakes.dart';

void main() {
  group('resolveConfig', () {
    const server = SshTarget('ssh.example.com', port: 2222, user: 'alice');
    late FakeSsh fake;

    setUp(() async => fake = await FakeSsh.create());

    test('throws SshNotFoundException when ssh is missing', () async {
      await expectLater(
        resolveConfig(server, executable: '/nonexistent/ssh'),
        throwsA(isA<SshNotFoundException>()),
      );
    });

    test('runs ssh -G for the destination', () async {
      await resolveConfig(server, executable: fake.path);

      expect(fake.configArguments, [
        '-G',
        ...['-p', '2222'],
        ...['-l', 'alice'],
        '--',
        'ssh.example.com',
      ]);
    });

    test('parses what ssh -G prints', () async {
      fake.answerConfig([
        'hostname ssh.example.com',
        'stricthostkeychecking ask\r',
        'connecttimeout none',
      ]);

      expect(await resolveConfig(server, executable: fake.path), {
        'hostname': 'ssh.example.com',
        'stricthostkeychecking': 'ask',
        'connecttimeout': 'none',
      });
    });

    test('is empty when ssh -G prints nothing', () async {
      expect(await resolveConfig(server, executable: fake.path), isEmpty);
    });

    test('is empty when ssh -G fails', () async {
      fake
        ..answerConfig(['hostname ssh.example.com'])
        ..failConfig();

      expect(await resolveConfig(server, executable: fake.path), isEmpty);
    });

    test('is empty and kills ssh -G when it outlives the timeout', () async {
      fake.hangOnConfig();

      expect(
        await resolveConfig(
          server,
          executable: fake.path,
          timeout: const Duration(seconds: 1),
        ),
        isEmpty,
      );
      expect(await stops(await fake.configPid), isTrue);
    });

    test('throws and kills ssh -G when aborted', () async {
      fake.hangOnConfig();
      final abort = Completer<void>();

      final resolving = resolveConfig(
        server,
        executable: fake.path,
        abortTrigger: abort.future,
      );
      final pid = await fake.configPid;
      abort.complete();

      await expectLater(resolving, throwsA(isA<SshTunnelAbortedException>()));
      expect(await stops(pid), isTrue);
    });

    test('throws without waiting when already aborted', () async {
      fake.hangOnConfig();

      await expectLater(
        resolveConfig(
          server,
          executable: fake.path,
          abortTrigger: Future.value(),
        ),
        throwsA(isA<SshTunnelAbortedException>()),
      );
    });

    test('ignores an abortTrigger that fails', () async {
      fake.answerConfig(['port 2222']);

      expect(
        await resolveConfig(
          server,
          executable: fake.path,
          abortTrigger: Future.error(StateError('ignored')),
        ),
        {'port': '2222'},
      );
    });
  });

  group('parseConfig', () {
    test('maps each option name to the rest of its line', () {
      expect(
        parseConfig([
          'hostname ssh.example.com',
          'port 22',
          'userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2',
        ]),
        {
          'hostname': 'ssh.example.com',
          'port': '22',
          'userknownhostsfile': '~/.ssh/known_hosts ~/.ssh/known_hosts2',
        },
      );
    });

    test('lowercases names but keeps values as written', () {
      expect(parseConfig(['LogLevel INFO']), {'loglevel': 'INFO'});
    });

    test('handles CRLF line endings', () {
      expect(parseConfig(['stricthostkeychecking ask\r', 'port 22\r']), {
        'stricthostkeychecking': 'ask',
        'port': '22',
      });
    });

    test('trims surrounding whitespace from each line and value', () {
      expect(parseConfig(['  connecttimeout   30  ']), {
        'connecttimeout': '30',
      });
    });

    test('skips blank lines and lines without a value', () {
      expect(parseConfig(['', '   ', 'batchmode', 'port 22']), {'port': '22'});
    });

    test('is empty for no lines', () {
      expect(parseConfig([]), isEmpty);
    });
  });
}
