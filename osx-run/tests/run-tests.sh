#!/usr/bin/env bash
set -Eeuo pipefail
. "$PWD/lib/testing/utils.sh"
export OSX_RUN_SKIP_SHELL=1
stub_env(){
 OSX_ROOT="$1"
 mkdir -p "$OSX_ROOT/bin" "$OSX_ROOT/env" "$OSX_ROOT/shims" "$OSX_ROOT/pkgs/osxcross/target/bin" "$OSX_ROOT/pkgs/osxcross/target/SDK" "$OSX_ROOT/pkgs/python/3.12.0/bin" "$OSX_ROOT/pkgs/node/22.7.0/bin" "$OSX_ROOT/wheelhouse/macosx_15_0_arm64" "$OSX_ROOT/site-macosx_15_0_arm64" "$OSX_ROOT/toolchains"
 cat > "$OSX_ROOT/bin/install" <<'EOF2'
#!/usr/bin/env bash
exit 0
EOF2
 chmod +x "$OSX_ROOT/bin/install"
 cat > "$OSX_ROOT/env/config.sh" <<EOF2
OSX_ROOT="$OSX_ROOT"
DEFAULT_ARCH="arm64"
DEFAULT_SDK_VER="15.5"
DEFAULT_DEPLOY_MIN="11.0"
EOF2
 cat > "$OSX_ROOT/env/pathrc.sh" <<'EOF2'
path_prepend_unique(){ p="$1"; case ":$PATH:" in *":$p:"*) PATH="$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: -v keep="$p" '!seen[$0]++ && $0!=keep{out=out $0 ":"} END{print keep ":" out}' | sed 's/:$//')" ;; *) PATH="$p:$PATH" ;; esac; export PATH; }
path_prepend_unique "$OSX_ROOT/bin"
EOF2
 cat > "$OSX_ROOT/env/pip-macos.conf" <<EOF2
[global]
no-index = true
find-links = $OSX_ROOT/wheelhouse/macosx_15_0_arm64
target = $OSX_ROOT/site-macosx_15_0_arm64
EOF2
 cat > "$OSX_ROOT/env/activate" <<EOF2
export PATH="$OSX_ROOT/pkgs/osxcross/target/bin:\$PATH"
export SDKROOT="$OSX_ROOT/pkgs/osxcross/target/SDK"
export MACOSX_DEPLOYMENT_TARGET="11.0"
export CC="xcrun clang"
export CXX="xcrun clang++"
export CFLAGS="-mmacos-version-min=11.0"
export CXXFLAGS="-stdlib=libc++ -mmacos-version-min=11.0"
export LDFLAGS="-stdlib=libc++"
EOF2
 cat > "$OSX_ROOT/toolchains/darwin-arm64.cmake" <<'EOF2'
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
EOF2
 cat > "$OSX_ROOT/pkgs/osxcross/target/bin/xcrun" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo xcrun; exit 0; }
[ "$1" = "--show-sdk-path" ] && { echo "$OSX_ROOT/pkgs/osxcross/target/SDK"; exit 0; }
exit 0
EOF2
 chmod +x "$OSX_ROOT/pkgs/osxcross/target/bin/xcrun"
 pypath=$(command -v python3)
 pippath=$(command -v pip3)
 ln -sf "$pypath" "$OSX_ROOT/pkgs/python/3.12.0/bin/python"
 ln -sf "$pypath" "$OSX_ROOT/pkgs/python/3.12.0/bin/python3"
 ln -sf "$pippath" "$OSX_ROOT/pkgs/python/3.12.0/bin/pip"
 ln -sf "$pippath" "$OSX_ROOT/pkgs/python/3.12.0/bin/pip3"
 ln -sf "$OSX_ROOT/pkgs/python/3.12.0" "$OSX_ROOT/pkgs/python/current"
 node_path=$(command -v node)
 npm_path=$(command -v npm)
 npx_path=$(command -v npx)
 cat > "$OSX_ROOT/pkgs/node/22.7.0/bin/node" <<EOF2
#!/usr/bin/env bash
if [ "\$1" = "-v" ] || [ "\$1" = "--version" ]; then echo "v22.7.0"; exit 0; fi
"$node_path" "\$@"
EOF2
 chmod +x "$OSX_ROOT/pkgs/node/22.7.0/bin/node"
 cat > "$OSX_ROOT/pkgs/node/22.7.0/bin/npm" <<EOF2
#!/usr/bin/env bash
"$npm_path" "\$@"
EOF2
 chmod +x "$OSX_ROOT/pkgs/node/22.7.0/bin/npm"
 cat > "$OSX_ROOT/pkgs/node/22.7.0/bin/npx" <<EOF2
#!/usr/bin/env bash
"$npx_path" "\$@"
EOF2
 chmod +x "$OSX_ROOT/pkgs/node/22.7.0/bin/npx"
 ln -sf "$OSX_ROOT/pkgs/node/22.7.0" "$OSX_ROOT/pkgs/node/current"
 cat > "$OSX_ROOT/bin/clang" <<'EOF2'
#!/usr/bin/env bash
o=a.out
while [ "$#" -gt 0 ]; do
case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac
done
printf '\xCF\xFA\xED\xFE' > "$o"
EOF2
 chmod +x "$OSX_ROOT/bin/clang"
 ln -sf clang "$OSX_ROOT/bin/clang++"
}
pass=0
fail=0
dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$dir/../../artifacts"
tmp_run=$(mktemp -d)
cp "$dir/../osx-run.sh" "$tmp_run"
RUN="$tmp_run/osx-run.sh"
chmod +x "$RUN"
export RUN
test_run(){
 t="$1"
 name=$(basename "$t")
 log="$dir/../../artifacts/${name%.sh}.log"
 work=$(mktemp -d)
 home=$(mktemp -d)
 OSX_ROOT="$work/opt/osx"
 HOME="$home"
 export OSX_ROOT HOME
 stub_env "$OSX_ROOT"
 echo "$name START"
 if run "$log" bash -x "$t"; then
  echo "$name PASS"
  pass=$((pass+1))
  [ -n "${TRACE:-}" ] && cat "/tmp/${name%.sh}.log"
 else
  echo "$name FAIL"
  fail=$((fail+1))
  echo "/tmp/${name%.sh}.log"
 fi
 rm -rf "$work" "$home"
}
self=$(realpath "$0")
tests=()
if [ "$#" -eq 0 ]; then
 for f in "$dir"/*.sh; do
  [ "$(realpath "$f")" = "$self" ] && continue
  tests+=("$f")
 done
else
 for a in "$@"; do
  [ "$(realpath "$a")" = "$self" ] && continue
  tests+=("$a")
 done
fi
printf 'bash %s\n' "$(bash --version | head -n1)"
printf 'zsh %s\n' "$(zsh --version 2>/dev/null | head -n1)"
printf 'clang %s\n' "$(clang --version 2>/dev/null | head -n1)"
printf 'lld %s\n' "$(ld.lld --version 2>/dev/null | head -n1)"
printf 'npm %s\n' "$(npm -v 2>/dev/null)"
printf 'node %s\n' "$(node -v 2>/dev/null)"
printf 'python %s\n' "$(python -V 2>&1)"
printf 'shellcheck %s\n' "$(shellcheck --version 2>/dev/null | head -n1)"
for t in "${tests[@]}"; do
 test_run "$t"
done
echo "passed $pass failed $fail"
rm -rf "$tmp_run"
[ "$fail" -eq 0 ]
