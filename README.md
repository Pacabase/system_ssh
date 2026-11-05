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
| `SshException` | anything else, such as `ClearAllForwardings` in your config |
| `ArgumentError` | a host or user ssh could misread, such as `-oProxyCommand=…`, or a `localPort` outside 1 to 65535 |

`isPermanent` says whether trying again can't work until something changes:
true for a missing ssh, a taken `localPort`, and an `SshTunnelException` for a
host key, a refused login or a broken ssh config. A dropped connection, a
timeout or a host that doesn't resolve while offline is worth retrying.

## Options it sets

`system_ssh` asks `ssh -G` what your config resolves to and only adds what an
unattended tunnel needs:

| Option | When |
|---|---|
| `ExitOnForwardFailure=yes`, `ControlPath=none` | always |
| `BatchMode=yes` | your config leaves it at `no` |
| `StrictHostKeyChecking=accept-new` | your config leaves it at `ask`; a changed key still fails |
| `ConnectTimeout=15` | your config sets none |
| `ServerAliveInterval=15` | your config sets none |
| `ForkAfterAuthentication=no` | your config turns it on |

The forward or proxy binds `127.0.0.1` only. `close()`, or your process
exiting, even by a crash, stops ssh and any `ProxyJump` or `ProxyCommand` it
started.

## Limits

- A `ProxyJump` host doesn't get these options; ssh doesn't pass them on.
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

Depend on the `SshClient` interface, and pass a fake in tests:

```dart
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
  Future<List<String>> configuredHosts() async => const ['ssh.example.com'];
}
```
