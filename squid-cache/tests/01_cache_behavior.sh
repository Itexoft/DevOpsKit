#!/usr/bin/env bash
set -Eeuo pipefail
o=$(mktemp)
base=$(dirname "$SQUID")
bash "$SQUID" start >"$o"
[ "$(tail -n1 "$o")" = started ]
u1="https://speed.hetzner.de/100MB.bin"
u2="https://speed.hetzner.de/200MB.bin"
cache="$base/cache"
[ -f "$base/mitm_ca/ca.crt" ]
[ -f /usr/local/share/ca-certificates/squid-mitm.crt ]
ts(){ date +%s%3N; }
s=$(ts)
basename "$u1" >&3
curl -# -L -o /dev/null "$u1" >&3
e=$(ts)
t1=$((e-s))
s=$(ts)
basename "$u2" >&3
curl -# -L -o /dev/null "$u2" >&3
e=$(ts)
t2=$((e-s))
c=$(find "$cache" -type f | wc -l)
[ "$c" -ge 2 ]
s=$(ts)
basename "$u1" >&3
curl -# -L -o /dev/null "$u1" >&3
e=$(ts)
t3=$((e-s))
s=$(ts)
basename "$u2" >&3
curl -# -L -o /dev/null "$u2" >&3
e=$(ts)
t4=$((e-s))
s=$(ts)
basename "$u1" >&3
curl -# -L -o /dev/null "$u1" >&3
e=$(ts)
t5=$((e-s))
s=$(ts)
basename "$u2" >&3
curl -# -L -o /dev/null "$u2" >&3
e=$(ts)
t6=$((e-s))
[ "$t3" -lt "$t1" ]
[ "$t4" -lt "$t2" ]
[ "$t5" -le "$t3" ]
[ "$t6" -le "$t4" ]
bash "$SQUID" stop >"$o"
[ "$(tail -n1 "$o")" = stopped ]
[ -f "$base/mitm_ca/ca.crt" ]
[ ! -f /usr/local/share/ca-certificates/squid-mitm.crt ]
if [ -f "$base/run/squid.pid" ]; then false; fi
c2=$(find "$cache" -type f | wc -l)
[ "$c2" -ge "$c" ]
echo "t1=$t1 t2=$t2 t3=$t3 t4=$t4 t5=$t5 t6=$t6"
