#!/usr/bin/env bash
set -Eeuo pipefail
if "$RUN" nonexistentcmd >/tmp/log 2>&1; then exit 1; fi
grep -q 'not found' /tmp/log
