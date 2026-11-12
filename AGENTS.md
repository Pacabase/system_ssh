# AGENTS.md

Guidance for coding agents (and people) working on `system_ssh`, a Dart package that opens SSH tunnels (`ssh -L`, to a host and port or a Unix socket), remote forwards (`ssh -R`) and SOCKS proxies (`ssh -D`) through the system's own `ssh`. [README.md](README.md) is the user-facing contract; keep it true.

## What the package promises

Every change must keep these promises:

- **It runs the system's own `ssh`.** Never add an SSH implementation. `~/.ssh/config` (`Host`, `Include`, `Match`, `ProxyJump`), agents including `IdentityAgent` sockets, hardware keys, certificates and `known_hosts` must work exactly as in a terminal.
- **It only adds what an unattended tunnel needs.** It asks `ssh -G` what the user's config resolves to and adds options only where the config leaves the default. The README's "Options it sets" table lists every one. Change both together.
- **Tunnels stay local and die with the process.** The forward or proxy it opens binds `127.0.0.1` only, and a remote forward asks the server for its `127.0.0.1`; forwards the user's config sets for the host open too. `close()`, or the app exiting, even by a crash, stops ssh and any `ProxyJump` or `ProxyCommand` it started (a job object on Windows).
- **It works on every OpenSSH it supports.** CI runs a real `sshd` on Ubuntu, macOS and Windows with each runner's own OpenSSH (the README's "Platforms" table). Don't rely on an ssh option or output that the oldest one lacks. `ssh` comes from the `PATH` (or `SystemSshClient`'s own path), and on Windows CI checks that it's the built-in OpenSSH.
- **Failures say why.** An app gets a typed exception, or a failed `done`, with ssh's reason and whether a retry is worth it, never a bare exit code.

## Code

- **Public API:** the package's API is what `lib/system_ssh.dart` exports (apps never import `lib/src`), and `test/public_api_test.dart` pins it. `lib/ssh_client.dart` exports all of it but `SystemSshClient`, and nothing it reaches may import `dart:io`, `dart:ffi` or `dart:isolate`; `test/ssh_client_library_test.dart` checks. Keep `SshClient` an interface that an app can fake. A change to it breaks those fakes, so call that out in the CHANGELOG.
- **Docs:** every public member has a dartdoc comment saying what it does for the caller, with an example where it helps. Inside `lib/src`, add a comment only for a reason the code can't show (an ssh quirk, a platform difference).
- **Dependencies:** this is a library, so use version ranges, not pins. CI also tests the lowest versions they allow (`dart pub downgrade`).
- **Style:** `final class` and `sealed class` where a type isn't meant to be extended, no abbreviations (`exception`, not `e`), and `catch (exception)`.

## Tests

- **Unit tests** run everywhere. They use the fake `ssh` in `test/fakes/`, compiled to an executable, that plays a scripted attempt (ready, fail, not found, bind failure). Cover the happy path, every failure path and the edge cases: aborting while connecting, a drop, closing twice.
- **Integration tests** are tagged `integration` and run only in CI (`SSH_TEST_PORT` set), against a real `sshd` started by `.github/actions/sshd`. Anything that depends on how real ssh behaves gets one.

## Changes and releases

- Add a CHANGELOG entry for each user-visible change, under `## Unreleased` at the top (create it if needed). Write it for the app developer: what they can do now, with a short example. Start a breaking change with **Breaking:** and say how to migrate.
- Never change the version in `pubspec.yaml` or tag a release in a pull request. The maintainer picks the version and tags it, and the publish workflow releases it to pub.dev.
- PR titles say what changes for a user, as a short imperative sentence ("Let openTunnel forward a fixed local port").

## Before you finish

Run what CI runs:

```bash
dart format .
dart analyze --fatal-infos
dart test --exclude-tags integration
dart pub publish --dry-run
```

CI also runs the unit tests on Dart 3.5, the oldest SDK `pubspec.yaml` allows, so don't use a newer API.
