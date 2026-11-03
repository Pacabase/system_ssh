## 0.2.0

- ssh runs with `BatchMode=yes` unless your config sets it, so a password or
  passphrase prompt fails at once with an `SshTunnelException` instead of
  waiting on a terminal. Use keys through an agent.

## 0.1.1

- `ssh -G` also stops when your process dies, and with it any `Match exec`
  command it started, on every platform.

## 0.1.0

- `SystemSshClient.openTunnel` forwards a free `127.0.0.1` port through the
  system's `ssh`, honouring `~/.ssh/config`, its agent and `ProxyJump`.
- `SshTunnel.done` completes when ssh exits; `abortTrigger` gives up while it
  connects.
