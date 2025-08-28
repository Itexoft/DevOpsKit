#!/usr/bin/env bash
set -Eeuo pipefail
"$RUN" install osxcross >/dev/null
sdk=$("$RUN" xcrun --show-sdk-path)
[ -n "$sdk" ]
export SDKROOT="$sdk"
[ "$SDKROOT" = "$sdk" ]
