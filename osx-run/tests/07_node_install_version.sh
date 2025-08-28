#!/usr/bin/env bash
set -Eeuo pipefail
ver=22.7.0
"$RUN" install node 22 >/dev/null
"$RUN" node -v | grep -q "v$ver"
"$RUN" npm -v >/dev/null
"$RUN" npx -v >/dev/null
