#!/bin/sh
# Builds the Windows password helper and its locator library into windows/,
# for x64 and arm64, with a pinned llvm-mingw so the same source always gives
# the same bytes. CI runs it and fails if the committed files differ.
#
#   tool/build_windows_helper.sh
set -eu

version=20261117
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    host=ucrt-ubuntu-22.04-x86_64
    sha256=e7a15a49a2ea95e9f3d8a9d0cfabe5052a4b10fb4777cc54de5a8c27b64bb701
    ;;
  Darwin-*)
    host=ucrt-macos-universal
    sha256=98d340bbb8d46b09ad6886ffba88bd9d5415e131c316de48e6bd7647377446aa
    ;;
  *)
    echo "No pinned llvm-mingw for $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/system_ssh
name=llvm-mingw-$version-$host
toolchain=$cache/$name

if [ ! -x "$toolchain/bin/clang" ]; then
  mkdir -p "$cache"
  archive=$cache/$name.tar.xz
  curl -fsSL -o "$archive" \
    "https://github.com/mstorsjo/llvm-mingw/releases/download/$version/$name.tar.xz"
  if command -v sha256sum >/dev/null; then
    actual=$(sha256sum "$archive" | cut -d' ' -f1)
  else
    actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
  fi
  if [ "$actual" != "$sha256" ]; then
    rm -f "$archive"
    echo "llvm-mingw's checksum is $actual, not $sha256" >&2
    exit 1
  fi
  tar -xJf "$archive" -C "$cache"
  rm -f "$archive"
fi

cd "$root"
# No timestamps, no symbols and no build paths, so a rebuild matches.
flags="-O2 -s -Wl,--no-insert-timestamp -ffile-prefix-map=$root=."
for arch in x64 arm64; do
  case $arch in
    x64) target=x86_64 ;;
    arm64) target=aarch64 ;;
  esac
  cc=$toolchain/bin/$target-w64-mingw32-clang
  mkdir -p "windows/$arch"
  # shellcheck disable=SC2086
  "$cc" $flags -municode -o "windows/$arch/system_ssh_askpass.exe" \
    src/askpass_helper.c -lws2_32
  # shellcheck disable=SC2086
  "$cc" $flags -shared -o "windows/$arch/system_ssh_askpass_locator.dll" \
    src/askpass_locator.c
done
