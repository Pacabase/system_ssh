import 'dart:convert';
import 'dart:io';

import 'package:system_ssh/src/processes.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fakes.dart';

void main() {
  group('startWatched', () {
    Future<Process> start(List<String> command) async {
      final process = await startWatched(command);
      addTearDown(process.kill);
      return process;
    }

    Future<Process> startSteps(List<String> steps) async =>
        start((await fakeCommand(steps)).arguments);

    test("passes the command's output through", () async {
      final process = await startSteps(['out:3', 'exit:0']);

      expect(await process.stdout.expand((chunk) => chunk).toList(), [0, 0, 0]);
      expect(await exitCodeOf(process), 0);
    });

    test('passes each argument through as is', () async {
      final process = await startSteps([r'echo:a  b "c" $d \e', 'exit:0']);

      expect(
        await process.stdout.transform(utf8.decoder).join(),
        startsWith(r'a  b "c" $d \e'),
      );
    });

    test('adds the environment to the inherited one', () async {
      final command = await fakeCommand([
        'env:SYSTEM_SSH_ADDED',
        'env:PATH',
        'exit:0',
      ]);
      final process = await startWatched(
        command.arguments,
        environment: {'SYSTEM_SSH_ADDED': 'one\ntwo'},
      );
      addTearDown(process.kill);

      expect(
        await process.stdout.transform(utf8.decoder).join(),
        'one\ntwo\n${Platform.environment['PATH']}\n',
      );
    });

    test("exits with the command's exit code", () async {
      final process = await startSteps(['exit:3']);

      expect(await exitCodeOf(process), 3);
    });

    test(
      'kill does nothing once the command has exited on Linux',
      skip: Platform.isLinux ? null : 'Linux only',
      () async {
        final process = await startSteps(['exit:3']);
        await exitCodeOf(process);

        expect(process.kill(), isFalse);
        expect(await exitCodeOf(process), 3);
      },
    );

    test('kill stops the command and what it started', () async {
      final command = await fakeCommand(['spawn', 'hang']);
      final process = await start(command.arguments);
      final pid = await command.pid;
      final childPid = await command.childPid;

      expect(isRunning(childPid), isTrue);

      process.kill();

      expect(await exitCodeOf(process), Platform.isWindows ? isNot(0) : 143);
      expect(await stops(pid), isTrue);
      expect(await stops(childPid), isTrue);
    });

    test('stops the command when this process is killed', () async {
      final command = await fakeCommand(['hang']);
      final helper = await Process.start(Platform.resolvedExecutable, [
        'test/fakes/start_watched_main.dart',
        ...command.arguments,
      ]);
      addTearDown(() => helper.kill(ProcessSignal.sigkill));
      final helperPid = int.parse(
        (await helper.stdout
                .transform(utf8.decoder)
                .first
                .timeout(const Duration(seconds: 30)))
            .trim(),
      );
      final pid = await command.pid;

      expect(isRunning(pid), isTrue);

      Process.killPid(helperPid, ProcessSignal.sigkill);

      expect(await stops(pid), isTrue);
    });

    test(
      "is this process's own child on Linux, for 1Password's prompt",
      skip: Platform.isLinux ? null : 'Linux only',
      () async {
        final command = await fakeCommand(['hang']);
        final process = await start(command.arguments);

        expect(await command.pid, process.pid);
        final stat = File('/proc/${process.pid}/stat').readAsStringSync();
        final parent = stat.substring(stat.lastIndexOf(')') + 2).split(' ')[1];
        expect(parent, '$pid');
      },
    );

    test(
      'throws SshNotFoundException for a command that does not exist',
      skip: Platform.isWindows ? null : 'POSIX starts /bin/sh, which exits 127',
      () async {
        await expectLater(
          startWatched([r'C:\nonexistent\ssh.exe']),
          throwsA(isA<SshNotFoundException>()),
        );
      },
    );
  });

  group(
    'startWatched through /bin/sh',
    skip: Platform.isWindows ? 'needs /bin/sh' : null,
    () {
      Future<Process> start(List<String> command) async {
        final process = await startWatched(command);
        addTearDown(process.kill);
        return process;
      }

      test('kills the command and what it started once stdin closes',
          skip: Platform.isLinux
              ? 'Linux stops it when this process dies, not on stdin'
              : null, () async {
        final command = await fakeCommand(['spawn', 'hang']);
        final process = await start(command.arguments);
        final pid = await command.pid;
        final childPid = await command.childPid;

        await process.stdin.close();

        expect(await exitCodeOf(process), 143);
        expect(await stops(pid), isTrue);
        expect(await stops(childPid), isTrue);
      });

      test('exits 143 when terminated', () async {
        final command = await fakeCommand(['hang']);
        final process = await start(command.arguments);
        await command.pid;

        process.kill();

        expect(await exitCodeOf(process), 143);
      });

      test('leaves nothing running when terminated at once', () async {
        final command = await fakeCommand(['hang']);
        final process = await start(command.arguments);

        process.kill();

        // 143 once sh's trap is set; before that, sh dies of the TERM.
        expect(await exitCodeOf(process), anyOf(143, terminated));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        for (final pid in command.pids) {
          expect(await stops(pid), isTrue);
        }
      });

      test('exits only after the terminated command has', () async {
        final directory = Directory.systemTemp.createTempSync('start_watched');
        addTearDown(() => directory.deleteSync(recursive: true));
        final cleaned = File('${directory.path}/cleaned');
        final process = await start([
          'sh',
          '-c',
          r'''trap 'sleep 0.3; touch "$1"; exit 1' TERM; echo ready; while :; do sleep 0.05; done''',
          'sh',
          cleaned.path,
        ]);
        await process.stdout.transform(utf8.decoder).first;

        process.kill();

        expect(await exitCodeOf(process), 143);
        expect(cleaned.existsSync(), isTrue);
      });

      test('exits 127 for a command that does not exist', () async {
        final process = await start(['/nonexistent/ssh']);

        expect(await exitCodeOf(process), 127);
      });
    },
  );

  group('resolveExecutable', () {
    for (final executable in [
      '/usr/bin/ssh',
      r'C:\Windows\System32\OpenSSH\ssh.exe',
      'bin/ssh',
      r'.\ssh.exe',
    ]) {
      test('leaves the path $executable alone', () {
        expect(resolveExecutable(executable), executable);
      });
    }

    test(
      'leaves a bare name to the PATH lookup',
      skip: Platform.isWindows ? 'Windows resolves it' : null,
      () {
        expect(resolveExecutable('ssh'), 'ssh');
        expect(
            resolveExecutable('ssh', environment: {'PATH': '/opt/bin'}), 'ssh');
        expect(resolveExecutable('system_ssh_no_such_tool'),
            'system_ssh_no_such_tool');
      },
    );

    group('on Windows', skip: Platform.isWindows ? null : 'Windows only', () {
      for (final name in ['cmd', 'cmd.exe', 'CMD']) {
        test('finds $name on the PATH as an absolute path', () {
          final resolved = resolveExecutable(name);

          expect(File(resolved).isAbsolute, isTrue);
          expect(resolved.toLowerCase(), endsWith(r'\cmd.exe'));
          expect(File(resolved).existsSync(), isTrue);
        });
      }

      for (final name in ['PATH', 'Path']) {
        test('finds a bare name on the $name the environment sets', () {
          final directory =
              Directory.systemTemp.createTempSync('resolve_executable');
          addTearDown(() => deleteSoon(directory));
          File('${directory.path}\\tool.exe').createSync();

          expect(
            resolveExecutable('tool', environment: {name: directory.path}),
            '${directory.path}\\tool.exe',
          );
        });
      }

      test('looks only on the PATH the environment sets', () {
        final directory =
            Directory.systemTemp.createTempSync('resolve_executable');
        addTearDown(() => deleteSoon(directory));

        expect(
          () => resolveExecutable('cmd', environment: {'PATH': directory.path}),
          throwsA(isA<SshNotFoundException>()),
        );
      });

      test('throws SshNotFoundException for a name not on the PATH', () {
        expect(
          () => resolveExecutable('system_ssh_no_such_tool'),
          throwsA(isA<SshNotFoundException>()),
        );
      });
    });
  });
}
