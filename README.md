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

- **`SshTarget`** takes an optional `port` and `user`; the rest comes from
  `~/.ssh/config`. Its `identityFile` logs in with that key alone, such as
  `~/.ssh/id_work`, from the file or your agent.
- **`localPort`** forwards a fixed port instead of a free one.
- **`bindAddress`** listens on another address of this computer instead of
  `127.0.0.1`: Docker's bridge `172.17.0.1` on Linux, `0.0.0.0` for every
  IPv4 network or `::` for every IPv6 one. Whatever can reach it can use the
  tunnel with no login. `openSocketTunnel` and `openSocksProxy` take it too.
  (Docker Desktop containers reach the default via `host.docker.internal`.)
- **`onLog`** gets each line ssh writes as an `SshLog`. It's information
  only: the tunnel's own failures are thrown, or fail `done`.
  - `SshProgress` while it connects.
  - `SshLoginStarted` as it connects, runs a `ProxyCommand` or
    authenticates: when an agent's or `ProxyCommand`'s prompt may need your
    app in front.
  - `SshForwardFailed`, with ssh's `reason`, for a connection through the
    open tunnel that couldn't be made: `SshForwardProhibited` when the
    server's config forbids it, else `SshForwardUnreachable`. Windows' sshd
    doesn't report these.
  - `SshMessage` for anything else.

  ```dart
  onLog: (log) => switch (log) {
    SshForwardProhibited() => print("The server doesn't allow this."),
    SshForwardUnreachable(:final reason) => print("Couldn't forward: $reason"),
    SshLoginStarted() => comeToTheFront(),
    SshProgress() || SshMessage() => print(log.line),
  },
  ```
- **`onPrompt`** answers what ssh asks while it logs in; see
  [Passwords and passphrases](#passwords-and-passphrases).
- **`abortTrigger`** gives up while it connects.
- **`tunnel.done`** completes once you `close()` the tunnel, and fails with
  an `SshException` saying why when the connection drops, usually an
  `SshDroppedException`.
- **`SystemSshClient(executable: ...)`** runs an `ssh` that isn't on the
  `PATH`.
- **`SystemSshClient(environment: ...)`** adds variables to ssh's
  environment; a bare `executable` is looked up on the `PATH` it sets.
- **`tunnelCommand(...)`** and `socksProxyCommand(...)` give the terminal
  command for the same tunnel, for an app to offer to copy:
  `ssh -N -L 127.0.0.1:15432:db.example.com:5432 ssh.example.com`.
- **`client.configuredHosts()`** lists the hosts named in `~/.ssh/config`
  and the files it includes.

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
your agent, and a login that needs an answer throws an
`SshLoginRefusedException`. With it, ssh asks your app. The answer never
goes through an argument, the environment or a file.

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

- **Kinds:** a key's passphrase, a password, or `SshCodePrompt` for what the
  server asks in its own words, such as a 2FA code. Show `text` as plain
  text: the server may have written it.
- **Cancel** by answering null: nothing more is asked, and the login throws
  an `SshLoginCancelledException`. An answer with a line break or over 1023
  bytes, the most ssh reads, cancels too, and so does an `onPrompt` that
  throws, which then throws its error.
- **A wrong answer** is asked again, up to `NumberOfPasswordPrompts` times
  (3 by default), then the login throws an `SshLoginRefusedException`.
- **One prompt at a time,** across every tunnel. Close your dialog when the
  prompt's `withdrawn` completes: ssh stopped waiting, such as when the
  tunnel was aborted. With `shareConnections`, a server asks once, not once
  per tunnel.
- **`isVerified`** is false before OpenSSH 8.5, which doesn't tell a
  server's questions from its own, so a server could word one as a
  passphrase prompt.
- **On Windows,** ssh asks through a small program that ships with the
  package. If it's missing or Windows won't run it, such as under an
  AppLocker policy, nothing asks, and `onLog` gets an `SshPromptsOff` saying
  why. 32-bit Windows doesn't ask.

### Building on Windows

The helper, `system_ssh_askpass.exe`, ships prebuilt for x64 and arm64, and
Dart or Flutter put it next to your app. Nothing is compiled on your machine.

- A command-line app builds with `dart build cli`, not `dart compile exe`,
  which refuses packages with build hooks, and ships the folder it makes.
  `dart run`, `dart test` and Flutter need nothing.
- If you sign your release file by file, sign `system_ssh_askpass.exe` too.

## Sharing a connection

Each tunnel runs its own ssh, so five tunnels to one server mean five logins:
five hardware-key touches, or five agent confirmations (`ssh-add -c`).
`shareConnections` has tunnels to the same server share one:

```dart
const client = SystemSshClient(shareConnections: true);

final db = await client.openTunnel(server, remoteHost: 'db', remotePort: 5432);
final cache = await client.openTunnel(server, remoteHost: 'cache', remotePort: 6379);
// One login for both.
```

- **Private:** it's your process's own ssh master, in a private directory.
  It never uses or becomes a `ControlMaster` from your ssh config.
- **Lifetime:** it starts with the first tunnel to a server and stops when
  the last one closes, or with your process, even by a crash. When it drops,
  every tunnel on it fails `done` together.
- **Same remote forward:** a second remote tunnel with the same forward (the
  same `remotePort`, or a server-picked port to the same local one) throws
  an `SshDuplicateForwardException` rather than log in again. Pass another
  `remotePort`, or reuse the open tunnel.
- **Same `localPort`:** two tunnels on one `localPort` with different
  `bindAddress`es each get the other's `SshForwardFailed`, since ssh names
  only the port.
- **Windows:** its OpenSSH can't share a connection, so each tunnel keeps
  its own ssh.

## Host keys

A tunnel has no terminal to ask whether to trust a new server. So where your
config leaves `StrictHostKeyChecking` at `ask`, a host not in `known_hosts` yet
throws an `SshUnknownHostKeyException`. Show its `hostKey` (`host`, `type`
and `fingerprint`, as `ssh-keygen -l` prints them), and once the user
accepts, `trustHostKey` adds it to their `known_hosts`:

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

- **`trustHostKey`** reads the key again without logging in, and writes it
  only if it still has the fingerprint you showed; otherwise it throws an
  `SshUnknownHostKeyException` with the new one. ssh writes the entry as
  `accept-new` would: hashed if your config sets `HashKnownHosts`, under the
  name ssh checks, in your first `UserKnownHostsFile`. Later connections
  don't ask again.
- **A changed key** throws an `SshHostKeyChangedException` with the key
  offered now, and nothing is written. The user removes the old one
  (`ssh-keygen -R <host>`) once they know why it changed.
- **Your config wins:** `StrictHostKeyChecking yes` fails with an
  `SshHostKeyRefusedException`; `accept-new` or `no` connects as ssh does.
- **`ProxyJump` hosts** are checked by their own ssh, so an unknown one fails
  with ssh's `Host key verification failed.` Connect to it once from a
  terminal. A host behind a `ProxyCommand` is asked about like any other.

## GUI apps

An app started from the macOS Dock or Finder doesn't get your shell
profile: its `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`. A Linux desktop
launcher usually reads `~/.profile` but not `~/.bashrc`, `~/.zshrc` or
`~/.zprofile`. So a `ProxyCommand` running a Homebrew `cloudflared` isn't
found, and an `SSH_AUTH_SOCK` from your profile isn't used. `loginShell`
gives ssh your login shell's `PATH`, `HOME`, `DISPLAY` and `SSH_` variables:

```dart
const client = SystemSshClient(loginShell: true);
```

- **Once per process:** it runs your shell on the first tunnel and keeps
  what it reads. If the shell fails or takes over 5 seconds, that tunnel
  goes without and the next one tries again.
- **Windows:** it does nothing, since apps already get your `PATH`.
- **`environment`** adds variables on top, and wins on a clash:

```dart
const client = SystemSshClient(
  loginShell: true,
  environment: {'AWS_PROFILE': 'staging'},
);
```

### macOS App Sandbox

Inside the App Sandbox (`com.apple.security.app-sandbox`, on in Flutter's
macOS template), ssh can't read `~/.ssh` or reach your agent, so turn it
off. That rules out the Mac App Store: ship with a Developer ID, notarized.

## Failures

Every failure is an `SshException`. Catch `SshPermanentException` for one
the user must fix first, and `SshTemporaryException` for one worth retrying:

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

- **Details:** each has a `message`, and when ssh said why, the `log` of
  everything it wrote and its `exitCode`.
- **New classes** come only in a breaking release, since one breaks a
  `switch` that names every class. Catching the two groups keeps working.

## Options it sets

It asks `ssh -G` what your config resolves to, and adds only what an
unattended tunnel needs:

| Option | When |
|---|---|
| `-n`, `-N`, `-T`, `-v` | always: no input, no remote command or terminal, and `-v` is how it tells the tunnel is open |
| `ExitOnForwardFailure=yes` | always |
| `ControlPath=none` | without `shareConnections`; with it, the shared connection gets `ControlMaster=yes`, `ControlPersist=no` and a `ControlPath` of its own, and each tunnel's `ssh -O` gets `ControlMaster=no`, `BatchMode=yes` and that `ControlPath` |
| `BatchMode=yes` | your config leaves it at `no`, without `onPrompt` |
| `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force` | in ssh's environment, with `onPrompt`; on Windows also `SYSTEM_SSH_ASKPASS_PORT` and `SYSTEM_SSH_ASKPASS_TOKEN`, for the helper to reach your app; before OpenSSH 8.4 also `DISPLAY=:0` unless one is set |
| `StrictHostKeyChecking=yes` | your config leaves it at `ask`; an unknown key throws an `SshUnknownHostKeyException` for you to ask about |
| `-i <file>`, `IdentitiesOnly=yes` | with `SshTarget`'s `identityFile` |
| `ConnectTimeout=15` | your config sets none |
| `trustHostKey`'s ssh | `StrictHostKeyChecking=accept-new`, a `UserKnownHostsFile` of a temp file before yours, `PreferredAuthentications=none`, `ClearAllForwardings=yes`, `PermitLocalCommand=no`, `ControlPath=none` and `BatchMode=yes`: it reads the key without logging in or forwarding |
| `ServerAliveInterval=15` | your config sets none |
| `ForkAfterAuthentication=no` | your config turns it on |

- **If `ssh -G` fails** or takes over 5 seconds, it adds every option above
  but `ForkAfterAuthentication=no`, so `StrictHostKeyChecking accept-new` or
  `no` in your config becomes `yes`.
- **Local only:** the forward or proxy binds `127.0.0.1` unless you pass
  another `bindAddress`. A remote forward asks for the server's `127.0.0.1`,
  which it gets unless its sshd sets `GatewayPorts yes`.
- **Dies with you:** `close()`, or your process exiting, even by a crash,
  stops ssh and any `ProxyJump` or `ProxyCommand` it started.

## Limits

- A `ProxyJump` host doesn't get these options, so an unknown one fails with
  ssh's own error, not an `SshUnknownHostKeyException`.
- Forwards your config sets for the host open too.
- Without `onPrompt`, a key with a passphrase needs an agent, and password
  and keyboard-interactive logins fail. `BatchMode no` in your config looks
  like the default, so it doesn't bring prompts back; `BatchMode yes` keeps
  ssh from asking even with `onPrompt`.
- Before OpenSSH 8.4, a command-line app run from a terminal gets ssh's own
  prompt there, not `onPrompt`.
- On Windows, a child that ssh starts in the instant before it joins its job
  object can outlive a crash.

## Platforms

Linux, macOS and Windows. Mobile and the web have no system `ssh`, so
there's no support there: see [When to use dartssh2
instead](#when-to-use-dartssh2-instead).

Tested in CI against a real `sshd`, with each runner's own OpenSSH:

| Runner | OpenSSH |
|---|---|
| Ubuntu 22.04, 24.04, 26.04 | 8.9, 9.6, 10.2 |
| macOS 15, 26 | 9.9, 10.3 |
| Windows Server 2022, 2025 | 9.5 |

And with an ssh the runners don't ship:

| Runner | OpenSSH |
|---|---|
| Ubuntu 24.04, built from source | 7.6, 8.0, 8.2, 8.4, 10.4, 10.5, 10.6 |
| macOS 26, Homebrew | the newest release |
| Windows Server 2025, Win32-OpenSSH | 10.4 |

## When to use dartssh2 instead

system_ssh only opens tunnels, and only where an `ssh` is installed. Use it
when a tunnel should open exactly as it does from your terminal, with what
your `ssh` already has:

- `Host` aliases, `ProxyJump`, `Include` and `Match` in `~/.ssh/config`
- your identity files, and your agent, including `IdentityAgent` sockets
  such as 1Password's
- hardware keys, such as a FIDO2 security key (`ed25519-sk`), and
  certificates
- the hosts you already trust in `known_hosts`

For commands, a shell or SFTP, or for iOS, Android or the web, use
[dartssh2](https://pub.dev/packages/dartssh2), an SSH client written in Dart
that needs no `ssh`.

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
