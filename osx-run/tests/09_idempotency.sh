#!/usr/bin/env bash
set -Eeuo pipefail
touch "$HOME/.bashrc"
"$RUN" true
h1=$(sha1sum "$HOME/.bashrc" | cut -d' ' -f1)
"$RUN" true
[ "$h1" = "$(sha1sum "$HOME/.bashrc" | cut -d' ' -f1)" ]
. "$OSX_ROOT/env/pathrc.sh"
. "$OSX_ROOT/env/pathrc.sh"
count=$(printf '%s' "$PATH" | grep -o "$OSX_ROOT/bin" | wc -l)
[ "$count" -eq 1 ]
