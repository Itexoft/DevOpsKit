#!/usr/bin/env bash
set -Eeuo pipefail
"$RUN" install osxcross >/dev/null
"$RUN" xcrun --version >/dev/null
"$RUN" xcrun --show-sdk-path | grep -q "$OSX_ROOT/pkgs/osxcross/target/SDK"
"$RUN" env | grep -q "SDKROOT=$OSX_ROOT/pkgs/osxcross/target/SDK"
[ -x "$OSX_ROOT/pkgs/osxcross/target/bin/xcrun" ]

