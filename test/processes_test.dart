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

    test('stops the command and what it started when this process is killed',
        () async {
      final command = await fakeCommand(['spawn', 'hang']);
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
      final childPid = await command.childPid;

      expect(isRunning(pid), isTrue);

      Process.killPid(helperPid, ProcessSignal.sigkill);

      expect(await stops(pid), isTrue);
      expect(await stops(childPid), isTrue);
    });

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

      test("is this process's own child, for 1Password's prompt", () async {
        final command = await fakeCommand(['hang']);
        final process = await start(command.arguments);

        expect(await command.pid, process.pid);
        expect(parentOf(process.pid), pid);
      });

      test('gives the command /dev/null as stdin', () async {
        final process = await start(['sh', '-c', 'cat; echo done']);

        expect(await process.stdout.transform(utf8.decoder).join(), 'done\n');
      });

      test('kill does nothing once the command has exited', () async {
        final command = await fakeCommand(['exit:3']);
        final process = await start(command.arguments);
        await exitCodeOf(process);

        expect(process.kill(), isFalse);
        expect(await exitCodeOf(process), 3);
      });

      for (final (how, stop) in [
        ('exits', (Process process) => Process.killPid(process.pid)),
        ('is killed', (Process process) => process.kill()),
      ]) {
        test('leaves no watcher behind once the command $how', () async {
          final command = await fakeCommand(['hang']);
          final process = await start(command.arguments);
          await command.pid;
          final watcher = childrenOf(pid)
              .where((child) => argumentsOf(child).endsWith(' ${process.pid}'))
              .single;

          stop(process);
          await exitCodeOf(process);

          expect(await stops(watcher), isTrue);
        });
      }

      test('exits 128 + the signal it died of', () async {
        final command = await fakeCommand(['hang']);
        final process = await start(command.arguments);
        await command.pid;

        process.kill(ProcessSignal.sigkill);

        expect(await exitCodeOf(process), 137);
      });

      test("ignores a terminal's Ctrl-C, as a background job does", () async {
        final command = await fakeCommand(['hang']);
        final process = await start(command.arguments);
        await command.pid;

        Process.killPid(process.pid, ProcessSignal.sigint);
        Process.killPid(process.pid);

        expect(await exitCodeOf(process), 128 + 15);
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

        expect(await exitCodeOf(process), 143);
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

int parentOf(int pid) => int.parse(_ps(['-o', 'ppid=', '-p', '$pid']));

List<int> childrenOf(int pid) => [
      for (final line
          in (Process.runSync('pgrep', ['-P', '$pid']).stdout as String)
              .split('\n'))
        if (int.tryParse(line) case final child?) child,
    ];

// Empty once the process is gone.
String argumentsOf(int pid) => _ps(['-o', 'args=', '-p', '$pid']);

String _ps(List<String> arguments) =>
    (Process.runSync('ps', arguments).stdout as String).trim();
