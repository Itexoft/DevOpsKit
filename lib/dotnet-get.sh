#!/usr/bin/env bash
set -Eeuo pipefail
set +H

[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 dotnet-sdk-<ver>-<os>-<arch> [DESTROOT]" >&2; exit 2; }

PKG="$1"
DESTROOT="${2:-.}"

case "$PKG" in
  dotnet-sdk-*-*-*) ;;
  *) echo "bad package: $PKG" >&2; exit 2 ;;
esac

host="$(uname -m 2>/dev/null || true)"
case "$host" in
  x86_64|amd64) host_arch="x64" ;;
  aarch64|arm64) host_arch="arm64" ;;
  *) host_arch="" ;;
esac

ARCH="${PKG##*-}"
TMP="${PKG%-*}"
OS="${TMP##*-}"
VER="${PKG#dotnet-sdk-}"
VER="${VER%-${OS}-${ARCH}}"

[ -n "$host_arch" ] && [ "$ARCH" != "$host_arch" ] && { echo "arch mismatch host=$host pkg=$ARCH" >&2; exit 1; }

BASE="https://builds.dotnet.microsoft.com/dotnet/Sdk"
URL="$BASE/$VER/$PKG.tar.gz"

DOTNET_ROOT="$DESTROOT/dotnet"
BIN_DIR="$DESTROOT/bin"
PROFILE_DIR="$DESTROOT/.profile.d"
CACHE_DIR="$DOTNET_ROOT/.cache"
TARBALL="$CACHE_DIR/$PKG.tar.gz"

mkdir -p "$CACHE_DIR" "$BIN_DIR" "$PROFILE_DIR"
curl -fL --proto '=https' --tlsv1.2 -o "$TARBALL" "$URL"
tar -xzf "$TARBALL" -C "$DOTNET_ROOT"
ln -sf "$DOTNET_ROOT/dotnet" "$BIN_DIR/dotnet"

printf '%s\n' "export DOTNET_ROOT=\"$DOTNET_ROOT\"" > "$PROFILE_DIR/dotnet.sh"
printf '%s\n' "export PATH=\"$BIN_DIR:\$PATH\"" >> "$PROFILE_DIR/dotnet.sh"

export DOTNET_ROOT="$DOTNET_ROOT"
export PATH="$BIN_DIR:$PATH"

"$BIN_DIR/dotnet" --info || true