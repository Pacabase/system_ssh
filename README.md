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
- `localPort` forwards a fixed `127.0.0.1` port instead of a free one.
- `onLog` gets what ssh says as an `SshLog` with its `line`: `SshProgress`
  while it connects, `SshForwardFailed` with a `reason` for a connection
  through the open tunnel that couldn't be made (Windows' sshd doesn't say),
  and `SshMessage` for anything else. They're information: the tunnel's own
  failures are thrown, or fail `done`.

  ```dart
  onLog: (log) => switch (log) {
    SshForwardFailed(:final reason) => print("Couldn't forward: $reason"),
    SshProgress() || SshMessage() => print(log.line),
  },
  ```
- `abortTrigger` gives up while it connects.
- `tunnel.done` completes once you `close()` the tunnel, and fails with an
  `SshTunnelException` saying why when the connection drops.
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
  throws an `SshTunnelException` with ssh's
  `Error: remote port forwarding failed for listen port 8080`.
- It takes `onLog` and `abortTrigger` as `openTunnel` does, and
  `remoteTunnelCommand(...)` gives the terminal command:
  `ssh -N -R 127.0.0.1:8080:localhost:3000 ssh.example.com`.

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
- Two tunnels can't share the same remote forward (the same `remotePort`, or
  a server-picked port to the same local one); the second throws.
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
  with ssh's own `SshTunnelException`, and `accept-new` or `no` connects as
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

It runs your shell once, on the first tunnel, gives up after 5 seconds, and
does nothing on Windows, where apps already get your `PATH`. `environment`
adds variables on top, and wins on a clash:

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

| Exception | When |
|---|---|
| `SshNotFoundException` | no `ssh` could be started; on Windows the message says how to add OpenSSH Client |
| `SshTunnelAbortedException` | `abortTrigger` completed first |
| `SshPortInUseException` | the `localPort` you asked for is taken |
| `SshTunnelException` | ssh exited before the tunnel opened; `log` and `exitCode` say why |
| `SshUnknownHostKeyException` | the server's host key isn't in `known_hosts` yet, and your config leaves `StrictHostKeyChecking` at `ask`; see [Host keys](#host-keys) |
| `SshHostKeyChangedException` | the server's host key doesn't match the one `known_hosts` holds for it |
| `SshConfigException` | your ssh config for the host stops the tunnel from working, such as `ClearAllForwardings yes` |
| `SshException` | anything else, such as a Windows job object that can't be set up |
| `ArgumentError` | a host or user ssh could misread, such as `-oProxyCommand=…`, or a `localPort` outside 1 to 65535 |

`isPermanent` says whether trying again can't work until something changes:
true for a missing ssh, a taken `localPort`, an `SshConfigException`, and an
`SshTunnelException` for a host key, a refused login or a broken ssh config. A
dropped connection, a timeout or a host that doesn't resolve while offline is
worth retrying.

## Options it sets

`system_ssh` asks `ssh -G` what your config resolves to and only adds what an
unattended tunnel needs:

| Option | When |
|---|---|
| `-n`, `-N`, `-T`, `-v` | always: no input, no remote command or terminal, and `-v` is how it tells the tunnel is open |
| `ExitOnForwardFailure=yes` | always |
| `ControlPath=none` | without `shareConnections`; with it, the shared connection gets `ControlMaster=yes`, `ControlPersist=no` and a `ControlPath` of its own, and each tunnel's `ssh -O` gets `ControlMaster=no`, `BatchMode=yes` and that `ControlPath` |
| `BatchMode=yes` | your config leaves it at `no` |
| `StrictHostKeyChecking=yes` | your config leaves it at `ask`; an unknown key throws an `SshUnknownHostKeyException` for you to ask about |
| `ConnectTimeout=15` | your config sets none |
| `trustHostKey`'s ssh | `StrictHostKeyChecking=accept-new`, a `UserKnownHostsFile` of a temp file before yours, `PreferredAuthentications=none`, `ClearAllForwardings=yes`, `PermitLocalCommand=no`, `ControlPath=none` and `BatchMode=yes`: it reads the key without logging in or forwarding |
| `ServerAliveInterval=15` | your config sets none |
| `ForkAfterAuthentication=no` | your config turns it on |

If `ssh -G` fails or takes over 5 seconds, it adds every option above but
`ForkAfterAuthentication=no`, so a `StrictHostKeyChecking accept-new` or `no`
in your config becomes `yes`.

The forward or proxy binds `127.0.0.1` only, and a remote forward asks the
server for its `127.0.0.1` only, which it gets unless its sshd sets
`GatewayPorts yes`. `close()`, or your process
exiting, even by a crash, stops ssh and any `ProxyJump` or `ProxyCommand` it
started.

## Limits

- A `ProxyJump` host doesn't get these options; ssh doesn't pass them on. So
  an unknown jump host fails with ssh's own error rather than an
  `SshUnknownHostKeyException`.
- Forwards your config sets for the host open too.
- Password and keyboard-interactive logins aren't supported yet, and a key
  with a passphrase needs an agent. A config that sets `BatchMode no` looks
  like the default, so it doesn't bring prompts back.
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
`package:system_ssh/interface.dart`: it has every type here but
`SystemSshClient`, and imports no `dart:io`.

```dart
import 'package:system_ssh/interface.dart';

class FakeSshClient implements SshClient {
  @override
  Future<SshTunnel> openTunnel(SshTarget server,
          {required String remoteHost,
          required int remotePort,
          int? localPort,
          void Function(SshLog log)? onLog,
          Future<void>? abortTrigger}) =>
      throw const SshTunnelException('Permission denied (publickey).');

  @override
  Future<SshTunnel> openSocksProxy(SshTarget server,
          {int? localPort,
          void Function(SshLog log)? onLog,
          Future<void>? abortTrigger}) =>
      throw const SshTunnelException('Permission denied (publickey).');

  @override
  Future<SshTunnel> openSocketTunnel(SshTarget server,
          {required String remoteSocket,
          int? localPort,
          void Function(SshLog log)? onLog,
          Future<void>? abortTrigger}) =>
      throw UnimplementedError();

  @override
  Future<SshRemoteTunnel> openRemoteTunnel(SshTarget server,
          {String localHost = 'localhost',
          required int localPort,
          int? remotePort,
          void Function(SshLog log)? onLog,
          Future<void>? abortTrigger}) =>
      throw UnimplementedError();

  @override
  Future<List<String>> configuredHosts() async => const ['ssh.example.com'];

  @override
  Future<void> trustHostKey(SshTarget server, SshHostKey hostKey,
      {Future<void>? abortTrigger}) async {}
}
```
