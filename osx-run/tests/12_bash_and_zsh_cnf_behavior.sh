#!/usr/bin/env bash
set -Eeuo pipefail
touch "$HOME/.bashrc" "$HOME/.zshrc"
"$RUN" true
dir=$(mktemp -d)
cd "$dir"
res=$("$RUN" bash -ic 'pwd')
[ "$res" = "$dir" ]
if command -v zsh >/dev/null; then
res=$("$RUN" zsh -ic 'pwd')
[ "$res" = "$dir" ]
fi

