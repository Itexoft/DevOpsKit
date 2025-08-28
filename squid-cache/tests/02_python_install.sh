#!/usr/bin/env bash
set -Eeuo pipefail
o=$(mktemp)
bash "$SQUID" start >"$o"
[ "$(tail -n1 "$o")" = started ]
tmp=$(mktemp -d)
ver=3.12
apt-get update >/dev/null
apt-get download "python${ver}-minimal" >&3
d=$(ls "python${ver}-minimal"_*.deb)
dpkg -x "$d" "$tmp"
[ -x "$tmp/usr/bin/python${ver}" ]
bash "$SQUID" stop >"$o"
[ "$(tail -n1 "$o")" = stopped ]
rm -rf "$tmp" "$d"
