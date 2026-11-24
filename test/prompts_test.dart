import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:system_ssh/src/askpass.dart';
import 'package:system_ssh/src/shared_connection.dart';
import 'package:system_ssh/src/ssh_command.dart';
import 'package:system_ssh/src/ssh_prompt.dart';
import 'package:system_ssh/src/system_ssh_client.dart';
import 'package:system_ssh/system_ssh.dart';
import 'package:test/test.dart';

import 'fakes/fake_ssh.dart';

void main() {
  const server = SshTarget('ssh.example.com');
  const passphrase = "Enter passphrase for key '/home/alice/.ssh/id_ed25519': ";
  const password = "alice@ssh.example.com's password: ";

  group('classifyPrompt', () {
    test("reads a key's passphrase prompt, with the key's path", () {
      expect(
        classifyPrompt(passphrase),
        isA<SshPassphrasePrompt>()
            .having((prompt) => prompt.keyPath, 'keyPath',
                '/home/alice/.ssh/id_ed25519')
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
    ]) {
      test('reads "$text" as a password', () {
        expect(classifyPrompt(text), SshPasswordPrompt(text));
      });
    }

    for (final text in [
      'Verification code: ',
      '(alice@ssh.example.com) Password: ',
      "Enter passphrase for key 'x': and more",
      '',
    ]) {
      test('reads "$text" as the server\'s own question', () {
        expect(classifyPrompt(text), SshCodePrompt(text));
      });
    }
  });

  group('canPrompt', () {
    test('lets every config ask outside Windows', () {
      expect(canPrompt(const {}, onWindows: false), isTrue);
      expect(
        canPrompt(const {'proxyjump': 'jump'}, onWindows: false),
        isTrue,
      );
    });

    test('lets a config without another ssh ask on Windows', () {
      expect(canPrompt(const {'batchmode': 'no'}, onWindows: true), isTrue);
    });

    for (final option in ['proxyjump', 'proxycommand']) {
      test('keeps a config with $option from asking on Windows', () {
        expect(
          canPrompt({'batchmode': 'no', option: 'x'}, onWindows: true),
          isFalse,
        );
      });
    }

    test('keeps an unread config from asking on Windows', () {
      expect(canPrompt(const {}, onWindows: true), isFalse);
    });

    for (final (option, value) in [
      ('user', 'a%OS%b'),
      ('hostname', 'host!PATH!'),
      ('identityfile', 'C:/keys/ok\nC:/keys/a"b'),
      ('certificatefile', 'C:/keys/a&b-cert.pub'),
    ]) {
      test('keeps a $option cmd.exe would read from asking on Windows', () {
        expect(
          canPrompt({'batchmode': 'no', option: value}, onWindows: true),
          isFalse,
        );
        expect(
          canPrompt({'batchmode': 'no', option: value}, onWindows: false),
          isTrue,
        );
      });
    }
  });

  group('sshCommand', () {
    const config = {'batchmode': 'no'};
    List<String> command({bool prompts = false, bool ownOnly = false}) =>
        sshCommand(
          server,
          forward: null,
          config: config,
          prompts: prompts,
          ownPromptsOnly: ownOnly,
        );

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

    test("turns the server's questions off for ssh's own prompts only", () {
      expect(
        command(prompts: true, ownOnly: true).join(' '),
        contains('-o KbdInteractiveAuthentication=no'),
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

    Future<SshTunnel> open({SshPromptHandler? onPrompt}) async {
      final tunnel = await openSystemForward(
        server,
        forward: localForwardTo('db.example.com', 3306),
        executable: fake.path,
        onPrompt: onPrompt,
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
      // A `"` can't reach the helper on Windows, see canPrompt, and cmd.exe
      // shows a `%NAME%` there as the variable's value.
      final prompt = Platform.isWindows
          ? r"Enter passphrase for key 'C:\a b&echo x^|<>(c)!\key': "
          : r"""Code '"$(touch x)`id`\n; & | < > \: """;
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

    test('throws SshLoginCancelledException when onPrompt answers null',
        () async {
      fake.asks({passphrase: null});

      await expectLater(
        open(onPrompt: (_) async => null),
        throwsA(
          isA<SshLoginCancelledException>()
              .having((exception) => exception.exitCode, 'exitCode', 255),
        ),
      );
      expect(fake.answers, ['<cancelled>']);
    });

    test('cancels an answer with a line break', () async {
      fake.asks({password: null});

      await expectLater(
        open(onPrompt: (_) async => 'one\ntwo'),
        throwsA(isA<SshLoginCancelledException>()),
      );
      expect(fake.answers, ['<cancelled>']);
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

        final helper = fake.attemptEnvironments.single['SSH_ASKPASS']!;
        expect(fake.answers, hasLength(1));
        expect(File(helper).parent.existsSync(), isFalse);
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
      expect(fake.answers, ['<cancelled>', '<cancelled>']);
    });

    test('throws SshTunnelAbortedException when aborted during a prompt',
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
      final helper = fake.attemptEnvironments.single['SSH_ASKPASS']!;
      expect(File(helper).parent.existsSync(), isFalse);
    });

    test('throws SshConfigException for OpenSSH before 8.4', () async {
      fake.version('OpenSSH_8.2p1 Ubuntu-4ubuntu0.11, OpenSSL 1.1.1f');

      await expectLater(
        open(onPrompt: (_) async => 'secret'),
        throwsA(
          isA<SshConfigException>().having(
              (exception) => exception.message, 'message', contains('8.4')),
        ),
      );
      expect(fake.attempts, isEmpty);
    });

    test('takes an ssh whose version it cannot read', () async {
      fake.version('ssh: some other build');

      await open(onPrompt: (_) async => 'secret');

      expect(fake.attempts, hasLength(1));
    });

    test(
      "asks only ssh's own prompts on Windows",
      () async {
        await open(onPrompt: (_) async => 'secret');

        expect(
          fake.attempts.single.join(' '),
          contains('-o KbdInteractiveAuthentication=no'),
        );
      },
      testOn: 'windows',
    );

    test(
      'asks nothing on Windows through a ProxyJump',
      () async {
        fake
          ..answerConfig(['host ssh.example.com', 'proxyjump jump'])
          ..asks({passphrase: null});

        await expectLater(
          open(onPrompt: (_) async => 'secret'),
          throwsA(isA<SshLoginRefusedException>()),
        );
        expect(fake.attemptEnvironments.single['SSH_ASKPASS'], isNull);
      },
      testOn: 'windows',
    );

    test(
      'asks through a ProxyJump, and lets the server ask, outside Windows',
      () async {
        fake
          ..answerConfig(['host ssh.example.com', 'proxyjump jump'])
          ..asks({passphrase: 'secret'});

        await open(onPrompt: (_) async => 'secret');

        expect(fake.answers, ['secret']);
        expect(
          fake.attempts.single.join(' '),
          isNot(contains('KbdInteractiveAuthentication')),
        );
      },
      testOn: '!windows',
    );

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

    test(
      'asks the tunnel that starts a shared connection',
      () async {
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
      },
      testOn: '!windows',
    );
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
    }) =>
        Process.run(
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

      final result = Process.run(
        slow.environment['SSH_ASKPASS']!,
        [password],
        environment: slow.environment,
      );
      await asked.future.timeout(const Duration(seconds: 20));
      await slow.close();

      expect(
        (await result.timeout(const Duration(seconds: 20))).exitCode,
        isNot(0),
      );
    });

    test('asks one prompt at a time', () async {
      var inFlight = 0;
      var most = 0;
      final queued = await AskPass.start((_) async {
        most = max(most, ++inFlight);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        inFlight--;
        return 'secret';
      });
      addTearDown(queued.close);

      final results = await Future.wait([
        for (var i = 0; i < 2; i++)
          Process.run(
            queued.environment['SSH_ASKPASS']!,
            [password],
            environment: queued.environment,
          ),
      ]).timeout(const Duration(seconds: 30));

      expect(results.map((result) => result.exitCode), [0, 0]);
      expect(most, 1);
    });

    test('keeps a failure that is not a refused login after a cancel',
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
    });

    test(
      "answers a prompt that isn't UTF-8",
      () async {
        final result = await Process.run('/bin/sh', [
          '-c',
          r'exec "$0" "$(printf "Code \377: ")"',
          askPass.environment['SSH_ASKPASS']!,
        ]).timeout(const Duration(seconds: 20));

        expect(result.exitCode, 0);
        expect(asked.single.text, 'Code \uFFFD: ');
      },
      testOn: '!windows',
    );

    test(
      'keeps the helper where only this user can open it',
      () async {
        final helper = askPass.environment['SSH_ASKPASS']!;
        final mode = (await Process.run('stat', [
          if (Platform.isMacOS) ...['-f', '%Lp'] else ...['-c', '%a'],
          File(helper).parent.path,
        ]))
            .stdout;

        expect('$mode'.trim(), '700');
      },
      testOn: '!windows',
    );
  });
}
