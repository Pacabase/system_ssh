# system_ssh

[![pub package](https://img.shields.io/pub/v/system_ssh.svg)](https://pub.dev/packages/system_ssh)
[![CI](https://github.com/Pacabase/system_ssh/actions/workflows/ci.yml/badge.svg)](https://github.com/Pacabase/system_ssh/actions/workflows/ci.yml)

SSH tunnels for Dart through the system's own `ssh`, so they open exactly as
they would from your terminal:

- `Host` aliases, `ProxyJump`, `Include` and `Match` in `~/.ssh/config`
- your agent, including `IdentityAgent` sockets such as 1Password's
- hardware keys, certificates and `known_hosts`

## Usage

```dart
import 'package:system_ssh/system_ssh.dart';

Future<void> main() async {
  const client = SystemSshClient();
  final tunnel = await client.openTunnel(
    const SshTarget('ssh.example.com'),
    remoteHost: 'db.example.com',
    remotePort: 5432,
  );

  print('db.example.com:5432 is on 127.0.0.1:${tunnel.localPort}');
  await tunnel.close();
}
```

- `SshTarget` takes an optional `port` and `user`; the rest comes from `~/.ssh/config`.
- `localPort` forwards a fixed port instead of a free one.
- `bindAddress` has the tunnel listen on another IP address of this
  computer: on Linux, Docker's bridge `172.17.0.1`, so containers can use
  it; `0.0.0.0` for every IPv4 network, or `::` for every IPv6 one (a tunnel
  listens on one or the other). Whatever can reach that address can use the
  tunnel, with no login of its own, so keep the default `127.0.0.1` unless
  that's what you want. `openSocketTunnel` and `openSocksProxy` take it too.
  With Docker Desktop on macOS or Windows, containers reach the default
  through `host.docker.internal` instead.
- `onLog` gets what ssh says as an `SshLog` with its `line`: `SshProgress`
  while it connects, `SshLoginStarted` as it connects to a server, runs a
  `ProxyCommand` or authenticates, which is when an agent's or a
  `ProxyCommand`'s prompt may need the app in front, `SshForwardFailed` with ssh's `reason` for a
  connection through the open tunnel that couldn't be made (Windows' sshd
  doesn't say), and `SshMessage` for anything else. A failed forward is
  `SshForwardProhibited` when the server's config forbids it, else
  `SshForwardUnreachable`. They're information: the tunnel's own
  failures are thrown, or fail `done`.

  ```dart
  onLog: (log) => switch (log) {
    SshForwardProhibited() => print("The server doesn't allow this."),
    SshForwardUnreachable(:final reason) => print("Couldn't forward: $reason"),
    SshLoginStarted() => comeToTheFront(),
    SshProgress() || SshMessage() => print(log.line),
  },
  ```
- `onPrompt` answers what ssh asks while it logs in; see
  [Passwords and passphrases](#passwords-and-passphrases).
- `abortTrigger` gives up while it connects.
- `tunnel.done` completes once you `close()` the tunnel, and fails with an
  `SshException` saying why when the connection drops, usually an
  `SshDroppedException`.
- `SystemSshClient(executable: ...)` runs an `ssh` that isn't on the `PATH`.
- `SystemSshClient(environment: ...)` adds variables to the environment ssh
  inherits; a bare `executable` is looked up on the `PATH` it sets.
- `tunnelCommand(...)` and `socksProxyCommand(...)` give the `ssh` command
  that opens the same tunnel from a terminal, for an app to offer to copy:
  `ssh -N -L 127.0.0.1:15432:db.example.com:5432 ssh.example.com`.
- `client.configuredHosts()` lists the hosts named in `~/.ssh/config` and the
  files it includes, for offering them to pick from.

ssh's output and the full command also go to the `system_ssh` logger of
[`package:logging`](https://pub.dev/packages/logging).

## SOCKS proxy

`openSocksProxy` serves a SOCKS5 proxy (`ssh -D`) whose connections the
server makes, to whatever host and port each client asks for:

```dart
final proxy = await client.openSocksProxy(const SshTarget('ssh.example.com'));

print('curl --socks5-hostname 127.0.0.1:${proxy.localPort} https://example.com');
```

It takes `localPort`, `onLog` and `abortTrigger` as `openTunnel` does. Point a
browser, or any SOCKS5 client, at the port.

## Unix socket

`openSocketTunnel` forwards a `127.0.0.1` port to a Unix socket on the
server, such as Docker's or PostgreSQL's:

```dart
final tunnel = await client.openSocketTunnel(
  const SshTarget('ssh.example.com'),
  remoteSocket: '/var/run/docker.sock',
);

print('DOCKER_HOST=tcp://127.0.0.1:${tunnel.localPort} docker ps');
```

It takes `localPort`, `onLog` and `abortTrigger` as `openTunnel` does, and
`socketTunnelCommand(...)` gives the terminal command. The path must be
absolute, the server's sshd must serve Unix sockets (OpenSSH on Linux and
macOS does), and the login must be allowed to open the socket. A connection
that can't reach it comes to `onLog` as an `SshForwardFailed`.

## Remote forward

`openRemoteTunnel` does the reverse (`ssh -R`): the server listens on its own
`127.0.0.1`, and each connection there comes back through ssh to a host and
port on your side, such as a dev server:

```dart
final tunnel = await client.openRemoteTunnel(
  const SshTarget('ssh.example.com'),
  localPort: 3000,
  remotePort: 8080,
);

print('On the server, curl http://127.0.0.1:${tunnel.remotePort}');
```

- Leave out `remotePort` to have the server pick a free one; `tunnel.remotePort`
  says which.
- `localHost` defaults to `localhost`; another host forwards to that machine,
  as this one reaches it.
- When the server port is taken, or its sshd doesn't allow forwarding, it
  throws an `SshFailedException` with ssh's
  `Error: remote port forwarding failed for listen port 8080`.
- It takes `onLog` and `abortTrigger` as `openTunnel` does, and
  `remoteTunnelCommand(...)` gives the terminal command:
  `ssh -N -R 127.0.0.1:8080:localhost:3000 ssh.example.com`.

## Passwords and passphrases

Without `onPrompt`, ssh asks nothing: a key with a passphrase works through
your agent, and a login that needs an answer fails with an
`SshLoginRefusedException`. With it, ssh asks your app through
`SSH_ASKPASS`, and your answer reaches ssh through a pipe, never an
argument, the environment or a file:

```dart
final tunnel = await client.openTunnel(
  const SshTarget('ssh.example.com'),
  remoteHost: 'db.example.com',
  remotePort: 5432,
  onPrompt: (prompt) => switch (prompt) {
    SshPassphrasePrompt(:final keyPath) => askForPassphrase(keyPath),
    SshPasswordPrompt() => askForPassword(prompt.text),
    SshCodePrompt() => askForCode(prompt.text),
  },
);
```

- `SshPassphrasePrompt` is a key file's passphrase, `SshPasswordPrompt` a
  password, and `SshCodePrompt` anything else, mostly what the server asks in
  its own words (keyboard-interactive), such as a 2FA code. Show `text` as
  plain text: the server may have written it.
- Answer null to cancel: nothing more is asked, and once ssh has no other
  way to log in, such as another key or your agent, it throws an
  `SshLoginCancelledException`. ssh is stopped before it would send an empty
  password or answer, which a server counts as a failed login. If `onPrompt` throws, the login is cancelled
  the same way and that error is thrown. An answer can't hold a line break;
  one that does cancels.
- A wrong passphrase or password is asked again up to
  `NumberOfPasswordPrompts` times (3 by default); the server decides how
  often it asks its own questions. Then it throws an
  `SshLoginRefusedException`.
- Prompts come one at a time, across every tunnel, and only while ssh logs
  in, a `ProxyJump` host included. A jump host's unknown host key is never
  asked about: it fails with an `SshHostKeyRefusedException`. The package
  doesn't time prompts out; the server ends a login nobody answers, usually
  after two minutes.
- A tunnel on a port the package picks can be retried if another program
  takes the port while ssh logs in, and the retry asks again.
- The helper runs from the temp folder, or, where that doesn't allow
  running programs, `XDG_RUNTIME_DIR` or `~/.cache`.
- With `shareConnections`, only the tunnel that starts the shared login is
  asked, so a server asks once, not once per tunnel. A tunnel with
  `onPrompt` and one without never share a connection.
- A config that sets `BatchMode yes` still keeps ssh from asking.
- On Windows and before OpenSSH 8.5, only ssh's own prompts come, a
  passphrase or a password. Keyboard-interactive logins are off there, so a
  server that takes passwords only that way, as many PAM setups do, refuses
  the login, and nothing asks when your config sets a `ProxyJump` or
  `ProxyCommand`, which runs another ssh, or when `ssh -G` can't read your
  config.
  - Before 8.5, ssh doesn't mark a server's questions with `(user@host)`,
    so a server could word one as ssh's own prompt. Before 8.4, ssh asks
    through `SSH_ASKPASS` only without a terminal, so a command-line app
    run from one gets ssh's own prompt there.
  - Windows' ssh runs the helper through `cmd.exe`, which would read a
    server's words, or a `%` or `"` in a name, as commands. So nothing asks
    there either when the user, host or a key file's path holds one of
    `" % ! ^ & | < >`.

## Sharing a connection

Each tunnel runs its own ssh, so five tunnels to one server mean five
logins and five connections: five touches of a hardware key that asks for
one on each login, or five confirmations from an agent that asks each time
(`ssh-add -c`). `shareConnections` has tunnels to the same server share one:

```dart
const client = SystemSshClient(shareConnections: true);

final db = await client.openTunnel(server, remoteHost: 'db', remotePort: 5432);
final cache = await client.openTunnel(server, remoteHost: 'cache', remotePort: 6379);
// One login for both.
```

- The connection is your process's own ssh master, in a private directory.
  It never uses or becomes a `ControlMaster` from your ssh config, so your
  terminal sessions are unaffected.
- It starts with the first tunnel to a server and stops once the last one
  closes, or with your process, even by a crash.
- When it drops, every tunnel on it fails `done` together.
- Two remote tunnels with the same forward, the same local host and port on
  the same server port or both on one the server picks, can't share it: the
  second throws an `SshDuplicateForwardException` rather than log in again.
  Pass another `remotePort`, or reuse the tunnel that's open.
- Two tunnels can't share the same remote forward (the same `remotePort`, or
  a server-picked port to the same local one); the second throws.
- Two tunnels on the same `localPort` but different `bindAddress`es each
  get the other's `SshForwardFailed`, since ssh names only the port.
- Windows' OpenSSH can't share a connection, so there each tunnel keeps its
  own ssh.

## Host keys

A terminal asks before it trusts a server it hasn't seen. A tunnel has no
terminal, so where your ssh config leaves `StrictHostKeyChecking` at `ask`,
opening one to a host that isn't in `known_hosts` yet throws an
`SshUnknownHostKeyException` instead. Its `hostKey` says what to show: the
`host` as `known_hosts` names it, the key's `type` and its `fingerprint`,
as `ssh-keygen -l` prints them. Once the user has checked the fingerprint,
`trustHostKey` adds the key to their `known_hosts`, and the tunnel opens:

```dart
Future<SshTunnel> open() => client.openTunnel(
      server,
      remoteHost: 'db.example.com',
      remotePort: 5432,
    );

try {
  return await open();
} on SshUnknownHostKeyException catch (exception) {
  final key = exception.hostKey;
  if (!await confirm('Trust ${key.host}? ${key.type} ${key.fingerprint}')) {
    rethrow;
  }
  await client.trustHostKey(server, key);
  return open();
}
```

- `trustHostKey` connects again to read the key, without logging in, and
  writes it only if the key ssh gets has the fingerprint you showed; if the
  server offers another by then, it throws an `SshUnknownHostKeyException`
  with that one, to ask about instead. ssh writes the
  entry itself, as `accept-new` would: hashed if your config sets
  `HashKnownHosts`, under the `HostKeyAlias` or `[host]:port` it checks, in the
  first `UserKnownHostsFile` (`~/.ssh/known_hosts` by default).
- From then on the key is known, so a reconnect doesn't ask again.
- A key that doesn't match `known_hosts` throws an
  `SshHostKeyChangedException`, from both the tunnel and `trustHostKey`, with
  the key the server offers now. Nothing is written; the user removes the old
  key (`ssh-keygen -R <host>`) once they know why it changed.
- A config that sets `StrictHostKeyChecking` gets what it sets: `yes` fails
  with an `SshHostKeyRefusedException` in ssh's words, and `accept-new` or `no` connects as
  ssh does. Set `accept-new` for a host to trust its first key unseen.
- A host behind a `ProxyCommand` is asked about like any other. A `ProxyJump`
  host's own key is checked by the ssh it starts, which gets none of these
  options, so an unknown one fails with ssh's `Host key verification failed.`
  Connect to it once from a terminal to trust it.

## GUI apps

An app started from the macOS Dock or Finder gets none of what your shell
profile sets: its `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`. On Linux a
desktop launcher usually reads `~/.profile`, but not `~/.bashrc`, `~/.zshrc`
or `~/.zprofile`. A `ProxyCommand` running `cloudflared` or `aws` from
Homebrew then isn't found, and an `SSH_AUTH_SOCK` exported in your shell
profile isn't used. Turn on
`loginShell` to give ssh your login shell's `PATH`, `HOME`, `DISPLAY` and
`SSH_` variables:

```dart
const client = SystemSshClient(loginShell: true);
```

It runs your shell on the first tunnel and keeps what it reads for the rest of
the process. If the shell fails or takes longer than 5 seconds, that tunnel
goes without and the next one runs the shell again. It does nothing on
Windows, where apps already get your `PATH`. `environment` adds variables on
top, and wins on a clash:

```dart
const client = SystemSshClient(
  loginShell: true,
  environment: {'AWS_PROFILE': 'staging'},
);
```

### macOS App Sandbox

A macOS app that uses `system_ssh` has to run without the App Sandbox
(`com.apple.security.app-sandbox`), which Flutter's macOS template turns on.
Inside the sandbox, ssh can't read `~/.ssh` or reach your agent.

That rules out the Mac App Store, which requires the sandbox. Ship the app
signed with a Developer ID and notarized instead.

## Failures

Every failure is an `SshException`, and each class is under one of two
sealed parents. Catch `SshPermanentException` for a failure that needs the
user to change something first, and `SshTemporaryException` for one worth
retrying:

```dart
try {
  return await client.openTunnel(server, remoteHost: 'db', remotePort: 5432);
} on SshTemporaryException {
  // Wait a little and try again.
} on SshPermanentException catch (exception) {
  // Stop, and say what to change.
}
```

| Exception | When |
|---|---|
| **`SshPermanentException`** | |
| `SshNotFoundException` | no `ssh` could be started; on Windows the message says how to add OpenSSH Client |
| `SshConfigException` | your ssh config for the host stops the tunnel: `ClearAllForwardings yes`, a bad option, a syntax error, the file's owner or permissions, or no algorithm the server offers (`Unable to negotiate`); or no folder lets `onPrompt`'s password prompt run |
| `SshPortInUseException` | the `localPort` you asked for is taken; `port` and `address` say which |
| `SshDuplicateForwardException` | with `shareConnections`, another open tunnel on the server already has the same remote forward; `forward` says which |
| `SshRemotePortRefusedException` | the server wouldn't listen on a remote forward's port, a remote tunnel's `remotePort` or one your config adds: it's taken there, or its sshd doesn't allow remote forwarding; `port` says which |
| `SshLoginRefusedException` | the server refused every login: `Permission denied (publickey)`, too many keys tried |
| `SshHostKeyRefusedException` | ssh refused a host key that isn't asked about: your config sets `StrictHostKeyChecking yes`, or a `ProxyJump` host's key is unknown or changed |
| `SshUnknownHostKeyException` | the server's host key isn't in `known_hosts` yet, and your config leaves `StrictHostKeyChecking` at `ask`; see [Host keys](#host-keys) |
| `SshHostKeyChangedException` | the server's host key doesn't match the one `known_hosts` holds for it |
| **`SshTemporaryException`** | |
| `SshHostNotFoundException` | the server's name didn't resolve, which offline it won't |
| `SshUnreachableException` | the connection was refused, timed out or had no route |
| `SshDroppedException` | the server closed or reset the connection, before the login or after, or stopped answering |
| `SshAddressUnavailableException` | the `bindAddress` isn't an address of this computer, at least not yet, such as a VPN's or Docker's before it comes up |
| `SshFailedException` | anything else, in ssh's words when it said why |
| **Neither** | |
| `SshTunnelAbortedException` | `abortTrigger` completed first |
| `SshLoginCancelledException` | the login failed after `onPrompt` answered null |
| `ArgumentError` | a host or user ssh could misread, such as `-oProxyCommand=…`, or a `localPort` outside 1 to 65535 |

Each has the `message`, and the `log` of everything ssh wrote and its
`exitCode` when ssh said why. A `switch` over the classes puts each in your
own words. A later version may add a class, which breaks a `switch` that names
every one, so it comes as a breaking release; catching the two groups keeps
working.

## Options it sets

`system_ssh` asks `ssh -G` what your config resolves to and only adds what an
unattended tunnel needs:

| Option | When |
|---|---|
| `-n`, `-N`, `-T`, `-v` | always: no input, no remote command or terminal, and `-v` is how it tells the tunnel is open |
| `ExitOnForwardFailure=yes` | always |
| `ControlPath=none` | without `shareConnections`; with it, the shared connection gets `ControlMaster=yes`, `ControlPersist=no` and a `ControlPath` of its own, and each tunnel's `ssh -O` gets `ControlMaster=no`, `BatchMode=yes` and that `ControlPath` |
| `BatchMode=yes` | your config leaves it at `no`, without `onPrompt` |
| `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force` | in ssh's environment, with `onPrompt`; on Windows also `SYSTEM_SSH_ASKPASS_PORT` and `SYSTEM_SSH_ASKPASS_TOKEN`, for the helper to reach your app; before OpenSSH 8.4 also `DISPLAY=:0` unless one is set |
| `KbdInteractiveAuthentication=no` | with `onPrompt` on Windows or before OpenSSH 8.5, whatever your config says; see [Passwords and passphrases](#passwords-and-passphrases) |
| `StrictHostKeyChecking=yes` | your config leaves it at `ask`; an unknown key throws an `SshUnknownHostKeyException` for you to ask about |
| `ConnectTimeout=15` | your config sets none |
| `trustHostKey`'s ssh | `StrictHostKeyChecking=accept-new`, a `UserKnownHostsFile` of a temp file before yours, `PreferredAuthentications=none`, `ClearAllForwardings=yes`, `PermitLocalCommand=no`, `ControlPath=none` and `BatchMode=yes`: it reads the key without logging in or forwarding |
| `ServerAliveInterval=15` | your config sets none |
| `ForkAfterAuthentication=no` | your config turns it on |

If `ssh -G` fails or takes over 5 seconds, it adds every option above but
`ForkAfterAuthentication=no`, so a `StrictHostKeyChecking accept-new` or `no`
in your config becomes `yes`.

The forward or proxy binds `127.0.0.1` unless you pass another
`bindAddress`, and a remote forward asks the server for its `127.0.0.1`
only, which it gets unless its sshd sets `GatewayPorts yes`. `close()`, or your process
exiting, even by a crash, stops ssh and any `ProxyJump` or `ProxyCommand` it
started.

## Limits

- A `ProxyJump` host doesn't get these options; ssh doesn't pass them on. So
  an unknown jump host fails with ssh's own error rather than an
  `SshUnknownHostKeyException`.
- Forwards your config sets for the host open too.
- Without `onPrompt`, a key with a passphrase needs an agent, and password
  and keyboard-interactive logins fail. A config that sets `BatchMode no`
  looks like the default, so it doesn't bring prompts back. On Windows,
  `onPrompt` asks less; see [Passwords and passphrases](#passwords-and-passphrases).
- On Windows, a child ssh starts in the instant before it joins its job object
  can outlive a crash.

## Platforms

Tested in CI against a real `sshd`, with each runner's own OpenSSH:

| Runner | OpenSSH |
|---|---|
| Ubuntu 22.04, 24.04, 26.04 | 8.9, 9.6, 10.2 |
| macOS 15, 26 | 9.9, 10.3 |
| Windows Server 2022, 2025 | 9.5 |

## Testing

Depend on the `SshClient` interface, and pass a fake in tests. Code that only
takes an `SshClient`, as this fake does, can import
`package:system_ssh/ssh_client.dart`: it has every type here but
`SystemSshClient`, and imports no `dart:io`.

```dart
import 'package:system_ssh/ssh_client.dart';

class FakeSshClient implements SshClient {
  @override
  Future<SshTunnel> openTunnel(SshTarget server,
          {required String remoteHost,
          required int remotePort,
          String bindAddress = '127.0.0.1',
          int? localPort,
          void Function(SshLog log)? onLog,
          SshPromptHandler? onPrompt,
          Future<void>? abortTrigger}) =>
      throw const SshLoginRefusedException('Permission denied (publickey).');

  @override
  Future<SshTunnel> openSocksProxy(SshTarget server,
          {String bindAddress = '127.0.0.1',
          int? localPort,
          void Function(SshLog log)? onLog,
          SshPromptHandler? onPrompt,
          Future<void>? abortTrigger}) =>
      throw const SshLoginRefusedException('Permission denied (publickey).');

  @override
  Future<SshTunnel> openSocketTunnel(SshTarget server,
          {required String remoteSocket,
          String bindAddress = '127.0.0.1',
          int? localPort,
          void Function(SshLog log)? onLog,
          SshPromptHandler? onPrompt,
          Future<void>? abortTrigger}) =>
      throw UnimplementedError();

  @override
  Future<SshRemoteTunnel> openRemoteTunnel(SshTarget server,
          {String localHost = 'localhost',
          required int localPort,
          int? remotePort,
          void Function(SshLog log)? onLog,
          SshPromptHandler? onPrompt,
          Future<void>? abortTrigger}) =>
      throw UnimplementedError();

  @override
  Future<List<String>> configuredHosts() async => const ['ssh.example.com'];

  @override
  Future<void> trustHostKey(SshTarget server, SshHostKey hostKey,
      {Future<void>? abortTrigger}) async {}
}
```
