#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = install ] && [ "${2:-}" = osxcross ]; then
if cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1; then
SCRIPT_DIR="${SCRIPT_DIR:-$(pwd -P)}"
else
SCRIPT_DIR="${SCRIPT_DIR:-$(pwd -P)}"
fi
cd "$SCRIPT_DIR"
: "${OSX_ROOT:=/opt/osx}"
: "${OSXCROSS_ROOT:=$OSX_ROOT/pkgs/osxcross}"
if [ -x "$OSXCROSS_ROOT/target/bin/xcrun" ]; then exit 0; fi
: "${SDK_VER:=15.5}"
: "${DEPLOY_MIN:=11.0}"
: "${ARCHES:=arm64}"
: "${XCODE_XIP:=}"
: "${SDK_TARBALL_URL:=}"
: "${OSX_RUN_SKIP_SHELL:=1}"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
/usr/bin/sudo apt-get update
/usr/bin/sudo apt-get install -y build-essential clang lld cmake git patch python3 xz-utils curl libssl-dev liblzma-dev libxml2-dev bzip2 cpio zlib1g-dev uuid-dev ninja-build pkg-config ca-certificates
f=""
for cand in "$(command -v ld64.lld || true)" "$HOME/.local/bin/ld64.lld" /usr/lib/llvm-*/bin/ld64.lld /usr/bin/ld64.lld-* /usr/lib/llvm-*/bin/ld.lld /usr/bin/ld.lld*; do [ -n "$cand" ] && [ -x "$cand" ] && { f="$cand"; break; }; done
if [ -z "$f" ]; then /usr/bin/sudo apt-get install -y lld-18 || /usr/bin/sudo apt-get install -y lld; for cand in "$(command -v ld64.lld || true)" "$HOME/.local/bin/ld64.lld" /usr/lib/llvm-*/bin/ld64.lld /usr/bin/ld64.lld-* /usr/lib/llvm-*/bin/ld.lld /usr/bin/ld.lld*; do [ -n "$cand" ] && [ -x "$cand" ] && { f="$cand"; break; }; done; fi
[ -n "$f" ] || { echo "Required dependency 'ld64.lld' is not installed"; exit 1; }
d="$HOME/.local/bin"
mkdir -p "$d"
ln -sf "$f" "$d/ld64.lld"
PATH="$d:$PATH"
export PATH
command -v ld64.lld >/dev/null 2>&1 || { echo "Required dependency 'ld64.lld' is not installed"; exit 1; }
/usr/bin/sudo mkdir -p "$OSXCROSS_ROOT"
/usr/bin/sudo chown "$(id -u)":"$(id -g)" "$OSXCROSS_ROOT"
cd "$OSXCROSS_ROOT"
if [ ! -d osxcross ]; then git clone --depth 1 --branch 2.0-llvm-based https://github.com/tpoechtrager/osxcross.git; fi
cd osxcross
mkdir -p tarballs
if [ -n "$SDK_TARBALL_URL" ]; then curl -fL -o "tarballs/MacOSX${SDK_VER}.sdk.tar.xz" "$SDK_TARBALL_URL" || true; fi
if ! ls tarballs/MacOSX*.sdk.tar.* >/dev/null 2>&1; then
if [ -n "$XCODE_XIP" ] && [ -f "$XCODE_XIP" ]; then ./tools/gen_sdk_package_pbzx.sh "$XCODE_XIP"; mv MacOSX*.sdk.tar.* tarballs/; else curl -fL -o "tarballs/MacOSX${SDK_VER}.sdk.tar.xz" "https://github.com/joseluisq/macosx-sdks/releases/download/${SDK_VER}/MacOSX${SDK_VER}.sdk.tar.xz" || true; fi
fi
ls tarballs/MacOSX*.sdk.tar.* >/dev/null 2>&1 || { echo "SDK tarball not found. Provide XCODE_XIP or SDK_TARBALL_URL or pre-place MacOSX${SDK_VER}.sdk.tar.* in tarballs/"; exit 1; }
UNATTENDED=1 ENABLE_ARCHS="$ARCHES" TARGET_DIR="$OSXCROSS_ROOT/target" ./build.sh
mkdir -p "$OSXCROSS_ROOT/env" "$OSXCROSS_ROOT/toolchains"
cat > "$OSXCROSS_ROOT/env/activate" <<EOF2
export PATH="$OSXCROSS_ROOT/target/bin:\$PATH"
export SDKROOT="\$(xcrun --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET="\${MACOSX_DEPLOYMENT_TARGET:-$DEPLOY_MIN}"
export CC="xcrun clang"
export CXX="xcrun clang++"
export CFLAGS="\${CFLAGS:-} -mmacos-version-min=\$MACOSX_DEPLOYMENT_TARGET"
export CXXFLAGS="\${CXXFLAGS:-} -stdlib=libc++ -mmacos-version-min=\$MACOSX_DEPLOYMENT_TARGET"
export LDFLAGS="\${LDFLAGS:-} -stdlib=libc++"
EOF2
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do [ -f "$rc" ] || continue; grep -q "$OSXCROSS_ROOT/env/activate" "$rc" || printf "%s\n" "test -f $OSXCROSS_ROOT/env/activate && . $OSXCROSS_ROOT/env/activate" >> "$rc"; done
cat > "$OSXCROSS_ROOT/toolchains/darwin-arm64.cmake" <<'EOF3'
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET $ENV{MACOSX_DEPLOYMENT_TARGET})
set(CMAKE_OSX_SYSROOT $ENV{SDKROOT})
set(CMAKE_C_COMPILER xcrun)
set(CMAKE_C_COMPILER_ARG1 clang)
set(CMAKE_CXX_COMPILER xcrun)
set(CMAKE_CXX_COMPILER_ARG1 clang++)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOF3
printf '#include <stdio.h>\nint main(){puts("ok");}\n' > "$SCRIPT_DIR/t.c"
PATH="$OSXCROSS_ROOT/target/bin:$PATH" SDKROOT="$(xcrun --show-sdk-path)" MACOSX_DEPLOYMENT_TARGET="$DEPLOY_MIN" xcrun clang -arch arm64 -mmacos-version-min="$DEPLOY_MIN" "$SCRIPT_DIR/t.c" -o "$SCRIPT_DIR/t_arm64"
if command -v file >/dev/null 2>&1; then file "$SCRIPT_DIR/t_arm64"; fi
echo OK
. "$OSXCROSS_ROOT/env/activate"
if [ -t 0 ] && [ -z "${OSX_RUN_SKIP_SHELL:-}" ]; then
SHELL_BIN="${SHELL:-/bin/bash}"
exec "$SHELL_BIN" -i
fi
exit 0
fi
if [ "${1:-}" = install ] && [ "${2:-}" = python ]; then
: "${OSX_ROOT:=/opt/osx}"
ver="${3:-3.11}"
for d in "$OSX_ROOT/pkgs/python/$ver" "$OSX_ROOT/pkgs/python/$ver"*; do [ -d "$d" ] && { ln -sfn "$d" "$OSX_ROOT/pkgs/python/current"; exit 0; }; done
lst="$(curl -fsL https://www.python.org/ftp/python/)"
case "$ver" in
*.*.*) fv="$ver" ;;
*.*) fv=""; for cand in $(printf '%s\n' "$lst" | grep -o "${ver}[.][0-9][0-9]*" | sort -Vr); do curl -fsI "https://www.python.org/ftp/python/$cand/python-$cand-macos11.pkg" && { fv="$cand"; break; }; done; [ -n "$fv" ] || fv="$ver.0" ;;
*) fv=""; for mv in $(printf '%s\n' "$lst" | grep -o "${ver}[.][0-9][0-9]*" | sort -Vr); do for cand in $(printf '%s\n' "$lst" | grep -o "${mv}[.][0-9][0-9]*" | sort -Vr); do curl -fsI "https://www.python.org/ftp/python/$cand/python-$cand-macos11.pkg" && { fv="$cand"; break 2; }; done; done; [ -n "$fv" ] || fv="$ver.0" ;;
esac
dir="$OSX_ROOT/pkgs/python/$fv"
if [ ! -x "$dir/bin/python3" ]; then
command -v 7z >/dev/null 2>&1 || /usr/bin/sudo apt-get install -y p7zip-full
command -v bsdtar >/dev/null 2>&1 || /usr/bin/sudo apt-get install -y libarchive-tools
mkdir -p "$(dirname "$dir")"
tmp="$(mktemp -d)"
curl -fL "https://www.python.org/ftp/python/$fv/python-$fv-macos11.pkg" -o "$tmp/pkg"
7z x "$tmp/pkg" -o"$tmp" >/dev/null
rm -rf "$tmp/Resources"
bsdtar -xf "$tmp/Python_Framework.pkg/Payload" -C "$tmp"
mv "$tmp/Versions/${fv%.*}" "$dir"
ln -sf "$dir/bin/python3" "$dir/bin/python"
rm -rf "$tmp"
fi
ln -sfn "$dir" "$OSX_ROOT/pkgs/python/current"
exit 0
fi
if [ "${1:-}" = install ] && [ "${2:-}" = node ]; then
: "${OSX_ROOT:=/opt/osx}"
: "${DEFAULT_ARCH:=arm64}"
ver="${3:-22}"
for d in "$OSX_ROOT/pkgs/node/$ver"*; do [ -d "$d" ] && { ln -sfn "$d" "$OSX_ROOT/pkgs/node/current"; exit 0; }; done
fv="$(curl -fsL https://nodejs.org/dist/index.json | grep -o "v${ver}[0-9.]*" | head -n1 | tr -d v)"
dir="$OSX_ROOT/pkgs/node/$fv"
if [ ! -x "$dir/bin/node" ]; then
mkdir -p "$dir"
tmp="$(mktemp -d)"
curl -fL "https://nodejs.org/dist/v$fv/node-v$fv-darwin-$DEFAULT_ARCH.tar.gz" -o "$tmp/node.tar.gz"
tar -xzf "$tmp/node.tar.gz" -C "$dir" --strip-components 1
rm -rf "$tmp"
fi
ln -sfn "$dir" "$OSX_ROOT/pkgs/node/current"
exit 0
fi
OSX_ROOT="${OSX_ROOT:-/opt/osx}"
DEFAULT_ARCH="${DEFAULT_ARCH:-arm64}"
DEFAULT_SDK_VER="${DEFAULT_SDK_VER:-15.5}"
DEFAULT_DEPLOY_MIN="${DEFAULT_DEPLOY_MIN:-11.0}"
SDK_MAJOR="${DEFAULT_SDK_VER%%.*}"
PLATFORM="macosx_${SDK_MAJOR}_0_${DEFAULT_ARCH}"
WHEELHOUSE="$OSX_ROOT/wheelhouse/$PLATFORM"
SITEDIR="$OSX_ROOT/site-$PLATFORM"
export WHEELHOUSE
path_prepend_unique() {
 d="$1"
 if [ -z "$d" ] || [ ! -d "$d" ]; then return 0; fi
 case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
}
pick_latest_dir() {
 b="$1"
 [ -d "$b" ] || { echo ""; return 0; }
 find "$b" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort -Vr | head -n1
}
PY_HOME=""
if [ -L "$OSX_ROOT/pkgs/python/current" ]; then
 PY_HOME="$OSX_ROOT/pkgs/python/current"
else
 pv="$(pick_latest_dir "$OSX_ROOT/pkgs/python")"
 if [ -n "$pv" ]; then
  PY_HOME="$OSX_ROOT/pkgs/python/$pv"
 fi
fi
NODE_HOME=""
if [ -L "$OSX_ROOT/pkgs/node/current" ]; then
 NODE_HOME="$OSX_ROOT/pkgs/node/current"
else
 nv="$(pick_latest_dir "$OSX_ROOT/pkgs/node")"
 if [ -n "$nv" ]; then
  NODE_HOME="$OSX_ROOT/pkgs/node/$nv"
 fi
fi
OSXCROSS_TGT="$OSX_ROOT/pkgs/osxcross/target"
[ -d "$OSXCROSS_TGT/bin" ] && path_prepend_unique "$OSXCROSS_TGT/bin"
[ -n "$NODE_HOME" ] && path_prepend_unique "$NODE_HOME/bin"
[ -n "$PY_HOME" ] && path_prepend_unique "$PY_HOME/bin"
path_prepend_unique "$OSX_ROOT/bin"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$DEFAULT_DEPLOY_MIN}"
if command -v xcrun >/dev/null 2>&1; then
 SDKROOT_VAL="$(xcrun --show-sdk-path 2>/dev/null || true)"
 if [ -n "$SDKROOT_VAL" ]; then
  export SDKROOT="$SDKROOT_VAL"
 fi
fi
if [ -n "$PY_HOME" ]; then
 if [ -f "$OSX_ROOT/env/pip-macos.conf" ]; then
  export PIP_CONFIG_FILE="$OSX_ROOT/env/pip-macos.conf"
 fi
 export PYTHONNOUSERSITE=1
 export PYTHONPATH="$SITEDIR${PYTHONPATH:+:$PYTHONPATH}"
fi
if [ -n "$NODE_HOME" ]; then
 export npm_config_platform=darwin
 export npm_config_arch="$DEFAULT_ARCH"
 export npm_config_target_arch="$DEFAULT_ARCH"
 if [ -n "$PY_HOME" ]; then
  export npm_config_python="$PY_HOME/bin/python"
 fi
fi
export CC="${CC:-xcrun clang}"
export CXX="${CXX:-xcrun clang++}"
export CFLAGS="${CFLAGS:-} -mmacos-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CXXFLAGS="${CXXFLAGS:-} -stdlib=libc++ -mmacos-version-min=$MACOSX_DEPLOYMENT_TARGET"
export LDFLAGS="${LDFLAGS:-} -stdlib=libc++"
if [ "$#" -eq 0 ]; then
 d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
 case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH"; export PATH; printf "export PATH=\"%s:\\$PATH\"\n" "$d" >> "$HOME/.bashrc"; printf "export PATH=\"%s:\\$PATH\"\n" "$d" >> "$HOME/.zshrc";; esac
 hash -r || true
 exit 0
fi
hash -r || true
exec "$@"
