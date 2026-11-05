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
