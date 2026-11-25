#!/usr/bin/env bash
# Builds the OpenSSH client tools of one portable release into $PREFIX/bin.
# VERSION and SHA256 name the release. OPENSSL=1.0 builds it on a static
# OpenSSL 1.0.2, for releases that predate OpenSSL 1.1.
set -euo pipefail

work=$(mktemp -d)
cd "$work"
curl -fsSL --retry 3 -o openssh.tar.gz \
  "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-$VERSION.tar.gz"
echo "$SHA256  openssh.tar.gz" | sha256sum -c -
tar xzf openssh.tar.gz
cd "openssh-$VERSION"

# Older releases read zlib 1.3 as older than 1.2.
configure=(--prefix="$PREFIX" --sysconfdir="$PREFIX/etc" --without-zlib-version-check)
if [ "${OPENSSL:-}" = 1.0 ]; then
  curl -fsSL --retry 3 -o openssl.tar.gz \
    https://github.com/openssl/openssl/releases/download/OpenSSL_1_0_2u/openssl-1.0.2u.tar.gz
  echo "ecd0c6ffb493dd06707d38b14bb4d8c2288bb7033735606569d8f90f89669d16  openssl.tar.gz" | sha256sum -c -
  tar xzf openssl.tar.gz -C "$work"
  (cd "$work/openssl-1.0.2u" &&
    ./config no-shared --prefix="$work/openssl" --openssldir="$work/openssl" >/dev/null &&
    make depend >/dev/null 2>&1 && make build_libs >/dev/null &&
    mkdir -p "$work/openssl/lib" "$work/openssl/include" &&
    cp libcrypto.a "$work/openssl/lib/" && cp -RL include/openssl "$work/openssl/include/")
  configure+=(--with-ssl-dir="$work/openssl")
fi
./configure "${configure[@]}" >/dev/null

tools=(ssh ssh-keygen ssh-keyscan ssh-agent ssh-add)
make -j"$(nproc)" "${tools[@]}" >/dev/null
mkdir -p "$PREFIX/bin"
cp "${tools[@]}" "$PREFIX/bin/"
