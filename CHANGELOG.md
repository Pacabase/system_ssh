## 0.5.0

- `SystemSshClient.configuredHosts()` lists the hosts named in `~/.ssh/config`
  and the files it includes (`Include`, globs too), in order and once each,
  leaving out `*` and `?` patterns and `!` negations.
- `onLog` also gets ssh's warnings once the tunnel is open, such as
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
