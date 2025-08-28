#!/usr/bin/env bash
set -Eeuo pipefail
. "$PWD/testing/assert.sh"
assert_env SQUID
o=$(mktemp)
base=$(dirname "$SQUID")
bash "$SQUID" start >"$o" || exit 1
[ "$(tail -n1 "$o")" = started ]
assert_file "$base/mitm_ca/ca.crt"
assert_file /usr/local/share/ca-certificates/squid-mitm.crt
bash "$SQUID" stop >"$o"
[ "$(tail -n1 "$o")" = stopped ]
[ ! -f /usr/local/share/ca-certificates/squid-mitm.crt ]
