#!/usr/bin/env bash
set -Eeuo pipefail
run(){
 log="$1"
 shift
 base=$(basename "$log")
 tmp="/tmp/$base"
 "$@" 2>&1 | tee "$tmp" | tee "$log" | sed '/^+/d'
 return "${PIPESTATUS[0]}"
}
