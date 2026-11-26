#!/usr/bin/env bash
# Opens an issue when the newest OpenSSH (`releases.sh openssh`) or
# Win32-OpenSSH (`releases.sh win32`) release isn't in CI's openssh job, unless
# one for it exists already. DRY_RUN=1 prints the issue instead.
set -euo pipefail

ci=${CI_FILE:-.github/workflows/ci.yml}
mirror=https://cdn.openbsd.org/pub/OpenBSD/OpenSSH
# Damien Miller's, which signs OpenSSH's portable releases. The key file comes
# from the mirror the tarball does, so only this fingerprint vouches for it.
release_key=7168B983815A5EEF59A4ADFD2A3F414E736060BA

# A closed issue counts too, so a release skipped on purpose stays skipped.
# Listed rather than searched, since search lags behind a new issue.
open_issue() { # title body
  local titles
  if [ -n "${DRY_RUN:-}" ]; then
    printf '%s\n\n%s\n' "$1" "$2"
    return
  fi
  titles=$(gh issue list --state all --limit 1000 --json title --jq '.[].title')
  if grep -Fxq "$1" <<<"$titles"; then
    echo "An issue exists: $1"
  else
    gh issue create --title "$1" --body "$2"
  fi
}

check_openssh() {
  local version work tarball sha256
  version=$(curl -fsSL "$mirror/portable/" |
    { grep -oE 'openssh-[0-9]+\.[0-9]+p[0-9]+\.tar\.gz' || true; } |
    sed -E 's/^openssh-//; s/\.tar\.gz$//' | sort -uV | tail -1)
  [ -n "$version" ] || { echo "No OpenSSH release listed on $mirror/portable/" >&2; exit 1; }
  if grep -qE "version: ${version//./\\.}," "$ci"; then
    echo "CI tests OpenSSH $version"
    return
  fi

  work=$(mktemp -d)
  tarball="$work/openssh-$version.tar.gz"
  curl -fsSL -o "$tarball" "$mirror/portable/openssh-$version.tar.gz"
  # A mirror can list the tarball before its signature arrives.
  if ! curl -fsSL -o "$tarball.asc" "$mirror/portable/openssh-$version.tar.gz.asc"; then
    echo "OpenSSH $version's signature isn't on the mirror yet"
    return
  fi
  mkdir -m 700 "$work/gnupg"
  curl -fsSL "$mirror/RELEASE_KEY.asc" | gpg -q --batch --homedir "$work/gnupg" --import
  gpg -q --batch --homedir "$work/gnupg" --status-fd 1 --verify "$tarball.asc" "$tarball" |
    grep '^\[GNUPG:\] VALIDSIG ' | grep -qw "$release_key" ||
    { echo "OpenSSH $version isn't signed by $release_key" >&2; exit 1; }
  sha256=$(sha256sum "$tarball" | cut -d' ' -f1)
  open_issue "Test OpenSSH $version" "OpenSSH $version is out, and CI doesn't test it yet. Its tarball is signed by OpenSSH's release key ($release_key).

Add it to the \`openssh\` job's matrix in \`.github/workflows/ci.yml\`, and to the README's Platforms table:

\`\`\`yaml
- { version: $version, sha256: $sha256 }
\`\`\`

Release notes: https://www.openssh.com/releasenotes.html"
}

check_win32() {
  local release tag name sha256
  release=$(curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
    https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest)
  tag=$(jq -r .tag_name <<<"$release")
  # Tags have been v9.5.0.0p1-Beta, V8.6.0.0p1-Beta, 10.4.0.0p1-Preview and 9.8.0.0.
  [[ $tag =~ ^[vV]?([0-9.]+(p[0-9]+)?)(-[A-Za-z]+)?$ ]] ||
    { echo "Unexpected Win32-OpenSSH tag: $tag" >&2; exit 1; }
  name=${BASH_REMATCH[1]}
  if grep -qF "win32: $tag," "$ci"; then
    echo "CI tests Win32-OpenSSH $tag"
    return
  fi

  sha256=$(jq -r '.assets[] | select(.name == "OpenSSH-Win64.zip") | .digest' <<<"$release")
  [[ $sha256 =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "No SHA-256 for $tag's OpenSSH-Win64.zip" >&2; exit 1; }
  open_issue "Test Win32-OpenSSH $name" "Win32-OpenSSH $tag is out, and CI doesn't test it yet.

Replace the Win32-OpenSSH line in the \`openssh\` job's matrix in \`.github/workflows/ci.yml\`, and its row in the README's Platforms table:

\`\`\`yaml
- { name: Win32-OpenSSH $name, os: windows-2025, win32: $tag, sha256: ${sha256#sha256:} }
\`\`\`

Release: https://github.com/PowerShell/Win32-OpenSSH/releases/tag/$tag"
}

case "${1:-}" in
  openssh) check_openssh ;;
  win32) check_win32 ;;
  *) echo "Usage: $0 openssh|win32" >&2; exit 2 ;;
esac
