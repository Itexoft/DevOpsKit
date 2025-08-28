#!/usr/bin/env bash
set -Eeuo pipefail
. "$OSX_ROOT/env/config.sh"
"$RUN" install node 22 >/dev/null
out=$("$RUN" npm config list -l)
printf '%s' "$out" | grep -q 'platform.*darwin'
printf '%s' "$out" | grep -q "arch.*$DEFAULT_ARCH"
printf '%s' "$out" | grep -q "target-arch.*$DEFAULT_ARCH"
