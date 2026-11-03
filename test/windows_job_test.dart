import 'dart:io';

import 'package:system_ssh/src/windows_job.dart';
import 'package:test/test.dart';

import 'fakes/fakes.dart';

void main() {
  group('startInJob', skip: !Platform.isWindows, () {
    Future<Process> start(FakeCommand command) async {
      final process = await startInJob(command.arguments);
      addTearDown(process.kill);
      return process;
    }

    test("passes the command's stdout and exit code through", () async {
      final process = await start(await fakeCommand(['out:3', 'exit:3']));

      expect(await process.stdout.expand((chunk) => chunk).toList(), [0, 0, 0]);
      expect(await exitCodeOf(process), 3);
    });

    test('kill stops the command and every process it started', () async {
      final command = await fakeCommand(['spawn', 'hang']);
      final process = await start(command);
      final childPid = await command.childPid;

      expect(isRunning(childPid), isTrue);

      expect(process.kill(), isTrue);

      expect(await exitCodeOf(process), isNot(0));
      expect(await stops(childPid), isTrue);
    });

    test('stops what the command left running once it exits', () async {
      final command = await fakeCommand(['spawn', 'exit:0']);
      final process = await start(command);
      final childPid = await command.childPid;

      expect(await exitCodeOf(process), 0);
      expect(await stops(childPid), isTrue);
    });

    test('kill does nothing to a command that already exited', () async {
      final process = await start(await fakeCommand(['exit:0']));
      await exitCodeOf(process);

      expect(process.kill(), isFalse);
      expect(await exitCodeOf(process), 0);
    });

    test('rethrows the ProcessException for a missing executable', () async {
      await expectLater(
        startInJob([r'C:\nonexistent\ssh.exe']),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
