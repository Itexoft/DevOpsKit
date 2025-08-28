#!/usr/bin/env bash
# TEST DISABLED!
exit 0
set -Eeuo pipefail
. "$PWD/testing/assert.sh"
assert_cmd tcpdump
assert_cmd curl
assert_env SQUID
o=$(mktemp)
bash "$SQUID" start >"$o"
[ "$(tail -n1 "$o")" = started ]
tmp=$(mktemp)
timeout 5 tcpdump -n -i lo port 3128 -c 1 >"$tmp" &
p=$!
sleep 1
curl -4 -L -o /dev/null http://example.com >&3
wait $p
grep -q 3128 "$tmp"
bash "$SQUID" stop >"$o"
[ "$(tail -n1 "$o")" = stopped ]
rm -f "$tmp"
