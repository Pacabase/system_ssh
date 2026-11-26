#!/usr/bin/env bash
# Opens an issue for the newest OpenSSH and Win32-OpenSSH releases when CI's
# openssh job doesn't test them yet, unless one is open already. DRY_RUN=1
# prints the issues instead.
set -euo pipefail

ci=${CI_FILE:-.github/workflows/ci.yml}
mirror=https://cdn.openbsd.org/pub/OpenBSD/OpenSSH
# Damien Miller's, which signs OpenSSH's portable releases. The key file comes
# from the mirror the tarball does, so only this fingerprint vouches for it.
release_key=7168B983815A5EEF59A4ADFD2A3F414E736060BA
work=$(mktemp -d)

open_issue() { # title body
  if [ -n "${DRY_RUN:-}" ]; then
    printf '%s\n\n%s\n' "$1" "$2"
  elif gh issue list --state open --limit 100 --search "$1 in:title" --json title --jq '.[].title' |
    grep -Fxq "$1"; then
    echo "Already open: $1"
  else
    gh issue create --title "$1" --body "$2"
  fi
}

version=$(curl -fsSL "$mirror/portable/" |
  grep -oE 'openssh-[0-9]+\.[0-9]+p[0-9]+\.tar\.gz' |
  sed -E 's/^openssh-//; s/\.tar\.gz$//' | sort -uV | tail -1)
if grep -qE "version: ${version//./\\.}," "$ci"; then
  echo "CI tests OpenSSH $version"
else
  tarball="$work/openssh-$version.tar.gz"
  curl -fsSL -o "$tarball" "$mirror/portable/openssh-$version.tar.gz"
  curl -fsSL -o "$tarball.asc" "$mirror/portable/openssh-$version.tar.gz.asc"
  mkdir -m 700 "$work/gnupg"
  curl -fsSL "$mirror/RELEASE_KEY.asc" | gpg -q --batch --homedir "$work/gnupg" --import
  gpg -q --batch --homedir "$work/gnupg" --status-fd 1 --verify "$tarball.asc" "$tarball" 2>/dev/null |
    grep '^\[GNUPG:\] VALIDSIG ' | grep -qw "$release_key" ||
    { echo "OpenSSH $version isn't signed by $release_key" >&2; exit 1; }
  sha256=$(sha256sum "$tarball" | cut -d' ' -f1)
  open_issue "Test OpenSSH $version" "OpenSSH $version is out, and CI doesn't test it yet. Its tarball is signed by OpenSSH's release key ($release_key).

Add it to the \`openssh\` job's matrix in \`.github/workflows/ci.yml\`, and to the README's Platforms table:

\`\`\`yaml
- { name: $version, os: ubuntu-24.04, version: $version, sha256: $sha256 }
\`\`\`

Release notes: https://www.openssh.com/releasenotes.html"
fi

release=$(curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
  https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest)
tag=$(jq -r .tag_name <<<"$release")
[[ $tag =~ ^v?[0-9.]+p[0-9]+(-Preview)?$ ]] || { echo "Unexpected Win32-OpenSSH tag: $tag" >&2; exit 1; }
if grep -qF "win32: $tag," "$ci"; then
  echo "CI tests Win32-OpenSSH $tag"
else
  sha256=$(jq -r '.assets[] | select(.name == "OpenSSH-Win64.zip") | .digest' <<<"$release")
  [[ $sha256 =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "No SHA-256 for $tag's OpenSSH-Win64.zip" >&2; exit 1; }
  name=${tag#v}
  name=${name%-Preview}
  open_issue "Test Win32-OpenSSH $name" "Win32-OpenSSH $tag is out, and CI doesn't test it yet.

Replace the Win32-OpenSSH line in the \`openssh\` job's matrix in \`.github/workflows/ci.yml\`, and its row in the README's Platforms table:

\`\`\`yaml
- { name: Win32-OpenSSH $name, os: windows-2025, win32: $tag, sha256: ${sha256#sha256:} }
\`\`\`

Release: https://github.com/PowerShell/Win32-OpenSSH/releases/tag/$tag"
fi
