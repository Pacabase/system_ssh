import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:system_ssh/src/askpass.dart';
import 'package:system_ssh/src/askpass_locator.dart';
import 'package:system_ssh/src/shared_connection.dart';
import 'package:system_ssh/src/ssh_command.dart';
import 'package:system_ssh/src/ssh_prompt.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';
import 'fakes/fakes.dart';

/// Checks that the helper ssh ran in [environment] is gone: its directory,
/// and on Windows the port it reached the app on. The program bundled on
/// Windows lives with the app, and stays.
Future<void> expectHelperRemoved(Map<String, String> environment) async {
  final helper = environment['SSH_ASKPASS']!;
  if (helper != bundledWindowsHelper) {
    expect(File(helper).parent.existsSync(), isFalse);
  }
  if (environment['SYSTEM_SSH_ASKPASS_PORT'] case final port?) {
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, int.parse(port)),
      throwsA(isA<SocketException>()),
    );
  }
}

void main() {
  const server = SshTarget('ssh.example.com');
  const passphrase = "Enter passphrase for key '/home/alice/.ssh/id_ed25519': ";
  const password = "alice@ssh.example.com's password: ";

  group('classifyPrompt', () {
    test("reads a key's passphrase prompt, with the key's path", () {
      expect(
        classifyPrompt(passphrase),
        isA<SshPassphrasePrompt>()
            .having(
              (prompt) => prompt.keyPath,
              'keyPath',
              '/home/alice/.ssh/id_ed25519',
            )
            .having((prompt) => prompt.text, 'text', passphrase),
      );
    });

    test("reads a Windows key's path", () {
      final prompt = classifyPrompt(
        r"Enter passphrase for key 'C:\Users\alice\.ssh\id_ed25519': ",
      );

      expect(
        prompt,
        isA<SshPassphrasePrompt>().having(
          (prompt) => prompt.keyPath,
          'keyPath',
          r'C:\Users\alice\.ssh\id_ed25519',
        ),
      );
    });

    for (final text in [
      password,
      "Enter alice@ssh.example.com's old password: ",
      "Enter alice@ssh.example.com's new password: ",
      "Retype alice@ssh.example.com's new password: ",
      "john smith@ssh.example.com's password: ",
    ]) {
      test('reads "$text" as a password', () {
        expect(classifyPrompt(text), SshPasswordPrompt(text));
      });
    }

    for (final text in [
      'Verification code: ',
      '(alice@ssh.example.com) Password: ',
      "(alice@jump.example.com) alice@db.example.com's password: ",
      "(alice@jump.example.com) Enter passphrase for key 'x': ",
      "Enter passphrase for key 'x': and more",
      "alice@host's password: and more",
      '',
    ]) {
      test('reads "$text" as the server\'s own question', () {
        expect(classifyPrompt(text), SshCodePrompt(text));
      });
    }
  });

  group('isHostKeyQuestion', () {
    test("reads ssh's questions about a host key", () {
      expect(
        isHostKeyQuestion(
          "The authenticity of host 'jump (10.0.0.2)' can't be established.\n"
          'ED25519 key fingerprint is SHA256:x.\n'
          'Are you sure you want to continue connecting (yes/no/[fingerprint])? ',
        ),
        isTrue,
      );
      expect(
        isHostKeyQuestion("Please type 'yes', 'no' or the fingerprint: "),
        isTrue,
      );
    });

    test("doesn't read a server's question as one", () {
      expect(
        isHostKeyQuestion(
          '(alice@host) Are you sure you want to continue connecting (yes/no)? ',
        ),
        isFalse,
      );
      expect(isHostKeyQuestion(passphrase), isFalse);
    });
  });

  group('sshCommand', () {
    const config = {'batchmode': 'no'};
    List<String> command({bool prompts = false}) =>
        sshCommand(server, forward: null, config: config, prompts: prompts);

    test('turns prompts off without them', () {
      expect(command().join(' '), contains('-o BatchMode=yes'));
      expect(command().join(' '), isNot(contains('KbdInteractive')));
    });

    test('leaves BatchMode to the config with them', () {
      expect(command(prompts: true).join(' '), isNot(contains('BatchMode')));
      expect(
        command(prompts: true).join(' '),
        isNot(contains('KbdInteractive')),
      );
    });
  });

  group('with a fake ssh', () {
    late FakeSsh fake;

    setUp(() async {
      fake = await FakeSsh.create()
        ..answerConfig(['host ssh.example.com', 'batchmode no'])
        ..attemptModes([AttemptMode.ready]);
    });

    Future<SshTunnel> open({
      SshPromptHandler? onPrompt,
      void Function(SshLog log)? onLog,
    }) async {
      final tunnel = await openSystemForward(
        server,
        forward: localForwardTo('db.example.com', 3306),
        executable: fake.path,
        onPrompt: onPrompt,
        onLog: onLog,
      );
      addTearDown(tunnel.close);
      return tunnel;
    }

    test('opens once onPrompt answers the passphrase', () async {
      fake.asks({passphrase: 'correct horse'});
      final prompts = <SshPrompt>[];

      await open(
        onPrompt: (prompt) async {
          prompts.add(prompt);
          return 'correct horse';
        },
      );

      expect(prompts, [
        const SshPassphrasePrompt(
          passphrase,
          keyPath: '/home/alice/.ssh/id_ed25519',
        ),
      ]);
      expect(fake.answers, ['correct horse']);
    });

    test('runs ssh with the helper and without BatchMode', () async {
      fake.asks({passphrase: null});

      await open(onPrompt: (_) async => 'secret');

      final environment = fake.attemptEnvironments.single;
      expect(environment, containsPair('SSH_ASKPASS_REQUIRE', 'force'));
      expect(environment['SSH_ASKPASS'], isNotNull);
      expect(fake.attempts.single.join(' '), isNot(contains('BatchMode')));
    });

    test('passes the answer and the prompt through as they are', () async {
      // Through the .cmd helper a `"` can't reach it, see canPrompt, and
      // cmd.exe shows a `%NAME%` as the variable's value.
      final prompt = Platform.isWindows && bundledWindowsHelper == null
          ? r"Enter passphrase for key 'C:\a b&echo x^|<>(c)!\key': "
          : r"""Code '"$(touch x)`id`\n; & | < > ^ ! %OS% \: """;
      const answer = r"""pa ss'"$(x)`y`\n;&|<>\ %PATH% ^ ! hörse €""";
      fake.asks({prompt: answer});
      final texts = <String>[];

      await open(
        onPrompt: (prompt) async {
          texts.add(prompt.text);
          return answer;
        },
      );

      expect(texts, [prompt]);
      expect(fake.answers, [answer]);
    });

    test('asks each prompt in turn', () async {
      fake.asks({passphrase: 'one', password: 'two'});
      final prompts = <SshPrompt>[];

      await open(
        onPrompt: (prompt) async {
          prompts.add(prompt);
          return prompt is SshPassphrasePrompt ? 'one' : 'two';
        },
      );

      expect(prompts, [isA<SshPassphrasePrompt>(), isA<SshPasswordPrompt>()]);
      expect(fake.answers, ['one', 'two']);
    });

    test('takes an empty answer', () async {
      fake.asks({password: null});

      await open(onPrompt: (_) async => '');

      expect(fake.answers, ['']);
    });

    test(
      'throws SshLoginCancelledException when onPrompt answers null',
      () async {
        fake.asks({passphrase: null});

        await expectLater(
          open(onPrompt: (_) async => null),
          throwsA(
            isA<SshLoginCancelledException>().having(
              (exception) => exception.exitCode,
              'exitCode',
              255,
            ),
          ),
        );
        expect(fake.answers, ['<cancelled>']);
      },
    );

    test('cancels an answer with a line break', () async {
      fake.asks({passphrase: null});

      await expectLater(
        open(onPrompt: (_) async => 'one\ntwo'),
        throwsA(isA<SshLoginCancelledException>()),
      );
      expect(fake.answers, ['<cancelled>']);
    });

    for (final (name, prompts) in [
      ('a cancelled password', {password: null}),
      (
        'a password after a cancelled passphrase',
        {passphrase: null, password: null},
      ),
      ("the server's question", {'Verification code: ': null}),
    ]) {
      test('stops ssh rather than send $name empty', () async {
        fake.asks(prompts);

        await expectLater(
          open(onPrompt: (_) async => null),
          throwsA(isA<SshLoginCancelledException>()),
        );
        // ssh never got an empty answer to send.
        expect(fake.answers, [
          for (final prompt in prompts.keys)
            if (prompt == passphrase) '<cancelled>',
        ]);
        expect(await stops(fake.attemptPid(1)!), isTrue);
      });
    }

    test('declines a host key question without asking or cancelling', () async {
      // The fake keeps a prompt to one line; ssh's comes after a few more.
      const question =
          'Are you sure you want to continue connecting (yes/no/[fingerprint])? ';
      fake.asks({question: null, passphrase: 'secret'});
      final asked = <SshPrompt>[];

      await expectLater(
        open(
          onPrompt: (prompt) async {
            asked.add(prompt);
            return 'secret';
          },
        ),
        throwsA(isA<SshLoginRefusedException>()),
      );
      expect(asked, [isA<SshPassphrasePrompt>()]);
      expect(fake.answers, ['<cancelled>', 'secret']);
    });

    test('throws what onPrompt throws', () async {
      fake.asks({passphrase: null});
      final error = StateError('no dialog');

      await expectLater(
        open(onPrompt: (_) => Future.error(error)),
        throwsA(same(error)),
      );
    });

    test('throws SshLoginRefusedException for a wrong answer', () async {
      fake.asks({passphrase: 'correct horse'});

      await expectLater(
        open(onPrompt: (_) async => 'wrong'),
        throwsA(isA<SshLoginRefusedException>()),
      );
    });

    test('asks nothing without onPrompt', () async {
      fake.asks({passphrase: null});

      await expectLater(open(), throwsA(isA<SshLoginRefusedException>()));
      expect(fake.answers, isEmpty);
      expect(fake.attemptEnvironments.single['SSH_ASKPASS'], isNull);
      expect(fake.attempts.single.join(' '), contains('-o BatchMode=yes'));
    });

    for (final (name, SshPromptHandler handler) in [
      ('the tunnel is open', (_) async => 'correct horse'),
      ('a cancel', (_) async => null),
      ('a wrong answer', (_) async => 'wrong'),
      ('onPrompt throws', (_) => Future.error(StateError('no dialog'))),
    ]) {
      test('removes the helper once $name', () async {
        fake.asks({passphrase: 'correct horse'});

        await open(onPrompt: handler).then((_) {}, onError: (Object _) {});

        expect(fake.answers, hasLength(1));
        await expectHelperRemoved(fake.attemptEnvironments.single);
      });
    }

    test('asks nothing more once a prompt is cancelled', () async {
      fake.asks({passphrase: null, password: null});
      var asked = 0;

      await expectLater(
        open(
          onPrompt: (_) async {
            asked++;
            return null;
          },
        ),
        throwsA(isA<SshLoginCancelledException>()),
      );
      expect(asked, 1);
      expect(fake.answers, ['<cancelled>']);
    });

    test(
      'throws SshTunnelAbortedException when aborted during a prompt',
      () async {
        fake.asks({passphrase: null});
        final abort = Completer<void>();
        final asked = Completer<void>();
        final answer = Completer<String?>();
        addTearDown(() {
          if (!answer.isCompleted) answer.complete(null);
        });

        final opening = openSystemForward(
          server,
          forward: localForwardTo('db.example.com', 3306),
          executable: fake.path,
          abortTrigger: abort.future,
          onPrompt: (_) {
            asked.complete();
            return answer.future;
          },
        );
        await asked.future.timeout(const Duration(seconds: 20));
        abort.complete();

        await expectLater(opening, throwsA(isA<SshTunnelAbortedException>()));
        await expectHelperRemoved(fake.attemptEnvironments.single);
      },
    );

    for (final (version, setsDisplay) in [
      ('OpenSSH_8.2p1 Ubuntu-4ubuntu0.11, OpenSSL 1.1.1f', true),
      ('OpenSSH_for_Windows_8.1p1, LibreSSL 3.0.2', true),
      ('OpenSSH_8.4p1 Debian-5+deb11u3, OpenSSL 1.1.1w', false),
    ]) {
      test('asks as a terminal would, unverified, on $version', () async {
        fake
          ..version(version)
          ..asks({passphrase: 'secret'});
        final prompts = <SshPrompt>[];

        await open(
          onPrompt: (prompt) async {
            prompts.add(prompt);
            return 'secret';
          },
        );

        expect(fake.answers, ['secret']);
        expect(prompts.single.isVerified, isFalse);
        expect(
          fake.attempts.single.join(' '),
          isNot(contains('KbdInteractiveAuthentication')),
        );
        if (setsDisplay) {
          expect(fake.attemptEnvironments.single['DISPLAY'], isNotNull);
        }
      });
    }

    test('asks through a ProxyJump on OpenSSH before 8.5', () async {
      fake
        ..version('OpenSSH_8.2p1 Ubuntu-4ubuntu0.11, OpenSSL 1.1.1f')
        ..answerConfig(['host ssh.example.com', 'proxyjump jump'])
        ..asks({passphrase: 'secret'});

      await open(onPrompt: (_) async => 'secret');

      expect(fake.answers, ['secret']);
      expect(
        fake.attempts.single.join(' '),
        isNot(contains('KbdInteractiveAuthentication')),
      );
    });

    test('lets the server ask on OpenSSH 8.5 and newer', () async {
      fake
        ..version('OpenSSH_8.5p1, OpenSSL 1.1.1k')
        ..asks({passphrase: 'secret'});
      final prompts = <SshPrompt>[];

      await open(
        onPrompt: (prompt) async {
          prompts.add(prompt);
          return 'secret';
        },
      );

      expect(prompts.single.isVerified, isTrue);
      expect(
        fake.attempts.single.join(' '),
        isNot(contains('KbdInteractiveAuthentication')),
      );
    });

    test('cancels an answer longer than ssh reads', () async {
      fake.asks({passphrase: null});

      await expectLater(
        open(onPrompt: (_) async => 'x' * 1024),
        throwsA(isA<SshLoginCancelledException>()),
      );
      expect(fake.answers, ['<cancelled>']);
    });

    test('takes an ssh whose version it cannot read', () async {
      fake.version('ssh: some other build');

      await open(onPrompt: (_) async => 'secret');

      expect(fake.attempts, hasLength(1));
    });

    group('on Windows', () {
      test('has the program the package ships', () {
        expect(bundledWindowsHelper, endsWith(r'\system_ssh_askpass.exe'));
      });

      test('runs it for every prompt, a ProxyJump\'s too', () async {
        fake
          ..answerConfig(['host ssh.example.com', 'proxyjump jump'])
          ..asks({'Verification code: ': '123456'});

        await open(onPrompt: (_) async => '123456');

        expect(
          fake.attemptEnvironments.single['SSH_ASKPASS'],
          bundledWindowsHelper,
        );
        expect(fake.answers, ['123456']);
      });

      test('asks nothing without the program, and says why', () async {
        final bundled = bundledWindowsHelper;
        bundledWindowsHelper = null;
        addTearDown(() => bundledWindowsHelper = bundled);
        fake.asks({passphrase: null});
        const why =
            "system_ssh_askpass.exe isn't with the app, so ssh can't ask";
        final logs = <SshLog>[];

        await expectLater(
          open(onPrompt: (_) async => 'secret', onLog: logs.add),
          throwsA(
            isA<SshLoginRefusedException>().having(
              (exception) => exception.message,
              'message',
              endsWith('(not asking for passwords: $why)'),
            ),
          ),
        );
        expect(fake.attemptEnvironments.single['SSH_ASKPASS'], isNull);
        expect(logs.first, const SshPromptsOff(why));
      });
    }, testOn: 'windows');

    test('asks through a SOCKS proxy', () async {
      fake.asks({passphrase: 'secret'});

      final proxy = await openSystemForward(
        server,
        forward: dynamicForwardOn('127.0.0.1'),
        executable: fake.path,
        onPrompt: (_) async => 'secret',
      );
      addTearDown(proxy.close);

      expect(fake.answers, ['secret']);
    });

    test('asks through a remote forward', () async {
      fake.asks({passphrase: 'secret'});

      final tunnel = await openSystemRemoteForward(
        server,
        localHost: 'localhost',
        localPort: 3000,
        remotePort: 8080,
        executable: fake.path,
        onPrompt: (_) async => 'secret',
      );
      addTearDown(tunnel.close);

      expect(fake.answers, ['secret']);
    });

    test('asks the tunnel that starts a shared connection', () async {
      fake.asks({passphrase: 'secret'});
      final pool = ConnectionPool();
      var asked = 0;

      Future<SshTunnel> share() async {
        final tunnel = await openSystemForward(
          server,
          forward: localForwardTo('db.example.com', 3306),
          executable: fake.path,
          pool: pool,
          onPrompt: (_) async {
            asked++;
            return 'secret';
          },
        );
        addTearDown(tunnel.close);
        return tunnel;
      }

      await share();
      await share();

      expect(asked, 1);
      expect(fake.answers, ['secret']);
    }, testOn: '!windows');

    test(
      "keeps a shared login's prompt when the tunnel that asked aborts",
      () async {
        fake.asks({passphrase: 'secret'});
        final pool = ConnectionPool();
        final asked = Completer<SshPrompt>();
        final answer = Completer<String?>();
        addTearDown(() {
          if (!answer.isCompleted) answer.complete(null);
        });
        final abort = Completer<void>();
        Future<SshTunnel> share({
          Future<void>? abortTrigger,
          required SshPromptHandler onPrompt,
        }) => openSystemForward(
          server,
          forward: localForwardTo('db.example.com', 3306),
          executable: fake.path,
          pool: pool,
          abortTrigger: abortTrigger,
          onPrompt: onPrompt,
        );

        final first = share(
          abortTrigger: abort.future,
          onPrompt: (prompt) {
            asked.complete(prompt);
            return answer.future;
          },
        );
        final prompt = await asked.future.timeout(const Duration(seconds: 20));
        final second = share(onPrompt: (_) async => null);
        // Long enough for the second to wait on the same login.
        await Future<void>.delayed(const Duration(seconds: 2));
        abort.complete();
        await expectLater(first, throwsA(isA<SshTunnelAbortedException>()));
        var isWithdrawn = false;
        unawaited(prompt.withdrawn.then((_) => isWithdrawn = true));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(isWithdrawn, isFalse);

        answer.complete('secret');
        final tunnel = await second.timeout(const Duration(seconds: 20));
        addTearDown(tunnel.close);

        expect(fake.answers, ['secret']);
        await prompt.withdrawn.timeout(const Duration(seconds: 20));
      },
      testOn: '!windows',
    );

    test("withdraws a prompt once its tunnel's login ends", () async {
      fake.asks({passphrase: null});
      final abort = Completer<void>();
      final asked = Completer<SshPrompt>();
      final opening = openSystemForward(
        server,
        forward: localForwardTo('db.example.com', 3306),
        executable: fake.path,
        abortTrigger: abort.future,
        onPrompt: (prompt) {
          asked.complete(prompt);
          return Completer<String?>().future;
        },
      );
      final prompt = await asked.future.timeout(const Duration(seconds: 20));

      abort.complete();

      await expectLater(opening, throwsA(isA<SshTunnelAbortedException>()));
      await prompt.withdrawn.timeout(const Duration(seconds: 20));
    });
  });

  group('AskPass', () {
    late AskPass askPass;
    var asked = <SshPrompt>[];

    setUp(() async {
      asked = [];
      askPass = await AskPass.start((prompt) async {
        asked.add(prompt);
        return 'secret';
      });
      addTearDown(askPass.close);
    });

    Future<ProcessResult> runHelper(
      String prompt, {
      Map<String, String> environment = const {},
    }) => Process.run(
      askPass.environment['SSH_ASKPASS']!,
      [prompt],
      environment: {...askPass.environment, ...environment},
    ).timeout(const Duration(seconds: 20));

    test('answers on stdout', () async {
      final result = await runHelper(password);

      expect(result.exitCode, 0);
      expect('${result.stdout}'.trim(), 'secret');
      expect(asked, [const SshPasswordPrompt(password)]);
    });

    test("doesn't ask about a notice ssh doesn't wait on", () async {
      final result = await runHelper(
        'Confirm user presence for key ED25519-SK',
        environment: {'SSH_ASKPASS_PROMPT': 'none'},
      );

      expect(result.exitCode, 0);
      expect(asked, isEmpty);
    });

    test('declines a yes/no question', () async {
      final result = await runHelper(
        'Are you sure?',
        environment: {'SSH_ASKPASS_PROMPT': 'confirm'},
      );

      expect(result.exitCode, isNot(0));
      expect(asked, isEmpty);
    });

    test('has a waiting helper give up once closed', () async {
      final asked = Completer<void>();
      final waiting = Completer<String?>();
      final slow = await AskPass.start((_) {
        asked.complete();
        return waiting.future;
      });
      addTearDown(slow.close);
      addTearDown(() {
        if (!waiting.isCompleted) waiting.complete(null);
      });

      final result = Process.run(slow.environment['SSH_ASKPASS']!, [
        password,
      ], environment: slow.environment);
      await asked.future.timeout(const Duration(seconds: 20));
      await slow.close();

      expect(
        (await result.timeout(const Duration(seconds: 20))).exitCode,
        isNot(0),
      );
    });

    test('asks one prompt at a time, across tunnels too', () async {
      var inFlight = 0;
      var most = 0;
      Future<String?> answer(SshPrompt _) async {
        most = max(most, ++inFlight);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        inFlight--;
        return 'secret';
      }

      final helpers = [for (var i = 0; i < 2; i++) await AskPass.start(answer)];
      for (final helper in helpers) {
        addTearDown(helper.close);
      }

      final results = await Future.wait([
        for (final helper in [helpers.first, ...helpers])
          Process.run(helper.environment['SSH_ASKPASS']!, [
            password,
          ], environment: helper.environment),
      ]).timeout(const Duration(seconds: 30));

      expect(results.map((result) => result.exitCode), [0, 0, 0]);
      expect(most, 1);
    });

    test('keeps a closed helper waiting in line from letting two in', () async {
      final firstAsked = Completer<void>();
      final firstAnswer = Completer<String?>();
      addTearDown(() {
        if (!firstAnswer.isCompleted) firstAnswer.complete(null);
      });
      var firstDone = false;
      var overlapped = false;
      final first = await AskPass.start((_) {
        firstAsked.complete();
        return firstAnswer.future;
      });
      final queued = await AskPass.start((_) async => 'secret');
      final last = await AskPass.start((_) async {
        if (!firstDone) overlapped = true;
        return 'secret';
      });
      for (final helper in [first, queued, last]) {
        addTearDown(helper.close);
      }
      Future<ProcessResult> run(AskPass helper) => Process.run(
        helper.environment['SSH_ASKPASS']!,
        [password],
        environment: helper.environment,
      );

      final firstResult = run(first);
      await firstAsked.future.timeout(const Duration(seconds: 20));
      unawaited(run(queued));
      // Long enough for its prompt to reach the line.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await queued.close();
      final lastResult = run(last);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      firstDone = true;
      firstAnswer.complete('secret');

      expect(
        (await lastResult.timeout(const Duration(seconds: 20))).exitCode,
        0,
      );
      await firstResult;
      expect(overlapped, isFalse);
    });

    test('lets a closed helper stop holding up the next prompt', () async {
      final asked = Completer<void>();
      final stuck = await AskPass.start((_) {
        asked.complete();
        return Completer<String?>().future;
      });
      addTearDown(stuck.close);
      final next = await AskPass.start((_) async => 'secret');
      addTearDown(next.close);

      unawaited(
        Process.run(stuck.environment['SSH_ASKPASS']!, [
          password,
        ], environment: stuck.environment),
      );
      await asked.future.timeout(const Duration(seconds: 20));
      await stuck.close();

      final result = await Process.run(next.environment['SSH_ASKPASS']!, [
        password,
      ], environment: next.environment).timeout(const Duration(seconds: 20));
      expect('${result.stdout}'.trim(), 'secret');
    });

    test('sets up in the next folder when one is unusable', () async {
      final helper = await AskPass.start(
        (_) async => 'secret',
        bases: ['/nonexistent/folder', Directory.systemTemp.path],
      );
      addTearDown(helper.close);

      expect(
        helper.environment['SSH_ASKPASS'],
        startsWith(Directory.systemTemp.path),
      );
    }, testOn: '!windows');

    test('throws SshConfigException when no folder is usable', () async {
      await expectLater(
        AskPass.start((_) async => 'secret', bases: ['/nonexistent/folder']),
        throwsA(isA<SshConfigException>()),
      );
    }, testOn: '!windows');

    test(
      'keeps a failure that is not a refused login after a cancel',
      () async {
        final cancelling = await AskPass.start((_) async => null);
        addTearDown(cancelling.close);
        await Process.run(
          cancelling.environment['SSH_ASKPASS']!,
          [passphrase],
          environment: cancelling.environment,
        ).timeout(const Duration(seconds: 20));

        const unreachable = SshUnreachableException('connection refused');
        expect(cancelling.failure(unreachable), same(unreachable));
        expect(
          cancelling.failure(const SshLoginRefusedException('denied')),
          isA<SshLoginCancelledException>(),
        );
      },
    );

    test("answers a prompt that isn't UTF-8", () async {
      final result = await Process.run('/bin/sh', [
        '-c',
        r'exec "$0" "$(printf "Code \377: ")"',
        askPass.environment['SSH_ASKPASS']!,
      ]).timeout(const Duration(seconds: 20));

      expect(result.exitCode, 0);
      expect(asked.single.text, 'Code \uFFFD: ');
    }, testOn: '!windows');

    test('keeps the helper where only this user can open it', () async {
      final helper = askPass.environment['SSH_ASKPASS']!;
      final mode = (await Process.run('stat', [
        if (Platform.isMacOS) ...['-f', '%Lp'] else ...['-c', '%a'],
        File(helper).parent.path,
      ])).stdout;

      expect('$mode'.trim(), '700');
    }, testOn: '!windows');
  });
}
