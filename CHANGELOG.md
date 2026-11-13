## Unreleased

- `tunnelCommand` and `remoteTunnelCommand` throw an `ArgumentError` for a
  `remoteHost` or `localHost` that `openTunnel` and `openRemoteTunnel`
  reject, such as a socket path or a host holding spaces or shell
  characters, instead of returning a command ssh would misread. An app that
  checks a tunnel by building its command, before saving it, now catches
  these too:

  ```dart
  try {
    remoteTunnelCommand(
      server,
      localHost: '/var/run/docker.sock',
      localPort: 3000,
      remotePort: 8080,
    );
  } on ArgumentError {
    // Not a tunnel ssh can open.
  }
  ```

## 0.9.0

- **Breaking:** `SshClient` has the new `openRemoteTunnel`,
  `openSocketTunnel` and `trustHostKey` methods, so a fake that implements
  `SshClient` needs them too. Each tunnel method can throw
  `UnimplementedError` if your tests never open one, and `trustHostKey` can do
  nothing if they never act out an unknown key. A fake acts one out with
  `throw SshUnknownHostKeyException(const SshHostKey(host: ..., type: ...,
  fingerprint: ...))`.
- **Breaking:** a tunnel no longer trusts a new host key unseen. Where the
  user's ssh config leaves `StrictHostKeyChecking` at `ask`, it used to pass
  `accept-new`, so the first connection trusted whatever key the server
  offered, as a terminal never does without asking. It now checks strictly,
  and a host that isn't in `known_hosts` yet throws an
  `SshUnknownHostKeyException` (an `SshTunnelException`, permanent) whose
  `hostKey` has the `host`, key `type` and `fingerprint` to show the user.
  `trustHostKey` adds it once they have checked it:

  ```dart
  } on SshUnknownHostKeyException catch (exception) {
    if (await confirm(exception.hostKey)) {
      await client.trustHostKey(server, exception.hostKey);
      // ...and open the tunnel again.
    }
  }
  ```

  It writes the key only if the server still offers that one, as ssh's
  `accept-new` would write it; if the server offers another key by then, it
  throws an `SshUnknownHostKeyException` with that key, for the app to ask
  about. To keep trusting new keys unseen, catch the exception and call
  `trustHostKey` without asking, or set `StrictHostKeyChecking accept-new` for
  the host in the ssh config, which the tunnel leaves alone. A config that
  sets `yes`, `accept-new` or `no` behaves as before, unless `ssh -G` can't
  read it (see the README's "Options it sets").
- `package:system_ssh/ssh_client.dart` has every type but `SystemSshClient`:
  `SshClient` and its tunnels, logs, targets, host keys and exceptions, and the
  terminal commands. It imports no `dart:io`, so code that only takes an
  `SshClient`, such as UI or a fake in tests, depends on nothing that starts
  ssh. `package:system_ssh/system_ssh.dart` still exports everything.
- `SshNotFoundException()` takes `onWindows: true` for the hint to add
  "OpenSSH Client" on Windows, rather than checking the platform itself; a
  fake that throws one gets the same message on every platform.
- A host key that doesn't match `known_hosts` throws an
  `SshHostKeyChangedException` with the key the server offers now, instead of
  a plain `SshTunnelException`; it is still an `SshTunnelException`, so
  catching that works as before.
- `openRemoteTunnel` opens a remote forward (`ssh -R`): the server listens on
  its `127.0.0.1`, and each connection there comes back to a host and port on
  your side, with the same options and failures as `openTunnel`. Leave out
  `remotePort` to have the server pick one, and read it from `remotePort`:

  ```dart
  final tunnel = await client.openRemoteTunnel(
    const SshTarget('ssh.example.com'),
    localPort: 3000,
  );
  print('The server reaches it on 127.0.0.1:${tunnel.remotePort}');
  ```

  `remoteTunnelCommand` gives the same forward as a terminal command.
- `openSocketTunnel` forwards a `127.0.0.1` port to a Unix socket on the
  server, such as Docker's or PostgreSQL's, and `socketTunnelCommand` gives
  the terminal command:

  ```dart
  final tunnel = await client.openSocketTunnel(
    const SshTarget('ssh.example.com'),
    remoteSocket: '/var/run/docker.sock',
  );
  // DOCKER_HOST=tcp://127.0.0.1:${tunnel.localPort}
  ```
- `SystemSshClient(shareConnections: true)` has tunnels to the same server
  share one ssh connection, so the server sees one login and the user touches
  a hardware key or confirms an agent's prompt once per server rather than
  once per tunnel:

  ```dart
  const client = SystemSshClient(shareConnections: true);
  ```

  The connection is the app's own, never the user's `ControlMaster`, and it
  stops with its last tunnel or the app. When it drops, every tunnel on it
  fails `done` together. On Windows, which can't share a connection, each
  tunnel keeps its own ssh.

## 0.8.0

- **Breaking:** `SshException` is now a `final class`, so an app can no
  longer extend or implement it. Catching it works as before. A fake
  `SshClient` that needs to act out a failure throws an `SshTunnelException`,
  such as `throw const SshTunnelException('Connection refused');`, and an
  app's own errors use its own exception type.
- When the user's ssh config sets `ClearAllForwardings yes` for the host,
  `openTunnel` and `openSocksProxy` throw an `SshConfigException`, whose
  `isPermanent` is true, instead of a plain `SshException`, so an app that
  reconnects on failures stops retrying and can tell the user to change their
  config:

  ```dart
  } on SshConfigException catch (exception) {
    showError('Check your ssh config: ${exception.message}');
  }
  ```
- On Linux and macOS, ssh is now a child of your app itself rather than of a
  `/bin/sh` wrapper, so a prompt that names the process asking, such as
  1Password's SSH agent approval on Linux, names your app instead of `/bin/sh`.
  ssh, and anything it started such as a ProxyCommand, still stops when the app
  exits or is killed, and still ignores a terminal's Ctrl-C.
- `tunnelCommand` and `socksProxyCommand` throw an `ArgumentError` (a
  `RangeError`) for a `localPort` outside 1 to 65535, as `openTunnel` and
  `openSocksProxy` do, instead of returning a command ssh would reject. Their
  documentation now says they throw, also for a host starting with `-`.

## 0.7.0

- `tunnelCommand` and `socksProxyCommand` give the `ssh` command that opens
  the same tunnel or SOCKS proxy from a terminal, quoted for a shell, such as
  `ssh -N -L 127.0.0.1:15432:db.example.com:5432 ssh.example.com`, for an app
  to offer to copy.
- **Breaking:** `onLog` gets an `SshLog` instead of a `String`: an
  `SshProgress` for ssh's `-v` progress, an `SshMessage` for anything else,
  or, once the tunnel is open, an `SshForwardFailed` with the `reason` a
  connection through it couldn't be forwarded, such as `Connection refused`
  from the destination or `administratively prohibited` from the server, so
  an app no longer matches ssh's `open failed` lines itself. To keep logging
  as before, change `onLog: (line) => …` to `onLog: (log) => …` and use
  `log.line`. Blank lines are no longer passed on.
- **Breaking for your own `SshClient` implementations, such as test fakes:**
  `openTunnel` and `openSocksProxy` take `void Function(SshLog log)? onLog`,
  and `configuredHosts()` moved from `SystemSshClient` to the `SshClient`
  interface, so a fake can offer hosts too.
- `SshTunnelException`'s documentation says it also comes from `done` when
  the connection drops.

## 0.6.0

- `SshException.isPermanent` says whether trying again can't work until
  something changes, so an app can reconnect a dropped tunnel and stop where
  that won't help. It is true for `SshNotFoundException`,
  `SshPortInUseException`, and an `SshTunnelException` when ssh refused a
  host key or a login, or couldn't read its config.

## 0.5.0

- `SystemSshClient.configuredHosts()` lists the hosts named in `~/.ssh/config`
  and the files it includes (`Include`, globs too), in order and once each,
  leaving out `*` and `?` patterns and `!` negations.
- `onLog` also gets ssh's warnings while the tunnel is open, such as
  `channel 2: open failed: connect failed: Connection refused` when the
  destination refuses a forwarded connection, without the `-v` progress.

## 0.4.0

- **Breaking:** `SshTunnel.done` fails with an `SshTunnelException` when ssh
  exits on its own, with ssh's reason (for example "Connection to … closed by
  remote host") and its last lines in `log`. It still completes normally after
  `close()`, and a caller that never listens to it isn't affected.

## 0.3.0

- `openSocksProxy` serves a SOCKS5 proxy (`ssh -D`) on `127.0.0.1`, through
  the server to whatever each client asks for.

## 0.2.0

- ssh runs with `BatchMode=yes` unless your config sets it, so a password or
  passphrase prompt fails at once with an `SshTunnelException` instead of
  waiting on a terminal. Use keys through an agent.
- On Windows, `SshNotFoundException` says to add "OpenSSH Client" under
  Optional features in Settings. It can no longer be created with `const`.
- `SystemSshClient(loginShell: true)` gives ssh your login shell's `PATH` and
  `SSH_AUTH_SOCK`, for GUI apps that start without them, and `environment`
  adds variables of your own.
- `openTunnel` takes an optional `localPort` to forward a fixed `127.0.0.1`
  port. A taken one fails with the new `SshPortInUseException`, before ssh
  starts when it can, and isn't retried.

## 0.1.1

- `ssh -G` also stops when your process dies, and with it any `Match exec`
  command it started, on every platform.

## 0.1.0

- `SystemSshClient.openTunnel` forwards a free `127.0.0.1` port through the
  system's `ssh`, honouring `~/.ssh/config`, its agent and `ProxyJump`.
- `SshTunnel.done` completes when ssh exits; `abortTrigger` gives up while it
  connects.
