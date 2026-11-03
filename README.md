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
- `onLog` gets ssh's output while it connects.
- `abortTrigger` gives up while it connects.
- `tunnel.done` completes when ssh exits, for example when the connection drops.
- `SystemSshClient(executable: ...)` runs an `ssh` that isn't on the `PATH`.

ssh's output and the full command also go to the `system_ssh` logger of
[`package:logging`](https://pub.dev/packages/logging).

## Failures

| Exception | When |
|---|---|
| `SshNotFoundException` | no `ssh` could be started |
| `SshTunnelAbortedException` | `abortTrigger` completed first |
| `SshTunnelException` | ssh exited before the tunnel opened; `log` and `exitCode` say why |
| `SshException` | anything else, such as `ClearAllForwardings` in your config |
| `ArgumentError` | a host or user ssh could misread, such as `-oProxyCommand=…` |

## Options it sets

`system_ssh` asks `ssh -G` what your config resolves to and only adds what an
unattended tunnel needs:

| Option | When |
|---|---|
| `ExitOnForwardFailure=yes`, `ControlPath=none` | always |
| `StrictHostKeyChecking=accept-new` | your config leaves it at `ask`; a changed key still fails |
| `ConnectTimeout=15` | your config sets none |
| `ServerAliveInterval=15` | your config sets none |
| `ForkAfterAuthentication=no` | your config turns it on |

The forward binds `127.0.0.1` only. `close()`, or your process exiting, even
by a crash, stops ssh and any `ProxyJump` or `ProxyCommand` it started.

## Limits

- A `ProxyJump` host doesn't get these options; ssh doesn't pass them on.
- Forwards your config sets for the host open too.
- ssh still asks for a password on a terminal or through `SSH_ASKPASS`; pass
  an `abortTrigger` so the caller can give up.
- On Windows, a child ssh starts in the instant before it joins its job object
  can outlive a crash.

## Platforms

Linux, macOS and Windows 10 1809 or later, with OpenSSH 7.6 or later.

## Testing

Depend on the `SshClient` interface, and pass a fake in tests:

```dart
class FakeSshClient implements SshClient {
  @override
  Future<SshTunnel> openTunnel(SshTarget server,
          {required String remoteHost,
          required int remotePort,
          void Function(String line)? onLog,
          Future<void>? abortTrigger}) =>
      throw const SshTunnelException('Permission denied (publickey).');
}
```
