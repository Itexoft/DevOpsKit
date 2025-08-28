#!/usr/bin/env bash
set -Eeuo pipefail
touch "$HOME/.bashrc" "$HOME/.zshrc"
PATH="/usr/bin"
"$RUN" true >/dev/null
p1="$PATH"
hb=$(sha1sum "$HOME/.bashrc" | cut -d' ' -f1)
hz=$(sha1sum "$HOME/.zshrc" | cut -d' ' -f1)
"$RUN" true >/dev/null
[ "$PATH" = "$p1" ]
[ "$hb" = "$(sha1sum "$HOME/.bashrc" | cut -d' ' -f1)" ]
[ "$hz" = "$(sha1sum "$HOME/.zshrc" | cut -d' ' -f1)" ]

