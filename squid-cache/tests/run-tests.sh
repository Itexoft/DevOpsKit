#!/usr/bin/env bash
set -Eeuo pipefail
dir="${BASH_SOURCE[0]%/*}"
. "$dir/../../lib/testing/utils.sh"
pass=0
fail=0
dir=$(cd "$dir" && pwd)
mkdir -p "$dir/../../artifacts"
tmp_run=$(mktemp -d)
cp "$dir/../squid-cache.sh" "$tmp_run"
SQUID="$tmp_run/squid-cache.sh"
chmod +x "$SQUID"
export SQUID
apt-get update -y
apt-get install -y tcpdump
test_run(){
 t="$1"
 name=$(basename "$t")
 log="$dir/../../artifacts/${name%.sh}.log"
 trace="/tmp/${name%.sh}.log"
 work=$(mktemp -d)
 home=$(mktemp -d)
 OSX_ROOT="$work/opt/osx"
 HOME="$home"
 export OSX_ROOT HOME
 mkdir -p "$OSX_ROOT"
 echo "$name START"
 if run "$log" bash -x "$t" 3>>"$trace"; then
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
printf 'python %s\n' "$(python -V 2>&1)"
printf 'shellcheck %s\n' "$(shellcheck --version 2>/dev/null | head -n1)"
for t in "${tests[@]}"; do
 test_run "$t"
done
echo "passed $pass failed $fail"
rm -rf "$tmp_run"
[ "$fail" -eq 0 ]
