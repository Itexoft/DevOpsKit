#!/usr/bin/env bash
assert_cmd(){ command -v "$1" >/dev/null 2>&1 || { printf '%s missing\n' "$1" >&2; return 1; }; }
assert_file(){ [ -f "$1" ] || { printf '%s missing\n' "$1" >&2; return 1; }; }
assert_env(){ [ -n "${!1:-}" ] || { printf '%s missing\n' "$1" >&2; return 1; }; }
