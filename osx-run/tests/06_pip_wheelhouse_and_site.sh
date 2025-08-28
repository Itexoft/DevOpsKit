#!/usr/bin/env bash
set -Eeuo pipefail
. "$OSX_ROOT/env/config.sh"
"$RUN" install python 3.12 >/dev/null
sdk_major="${DEFAULT_SDK_VER%%.*}"
platform="macosx_${sdk_major}_0_${DEFAULT_ARCH}"
wh="$OSX_ROOT/wheelhouse/$platform"
sd="$OSX_ROOT/site-$platform"
mkdir -p "$wh"
curl -fL -o "$wh/idna-3.7-py3-none-any.whl" "https://files.pythonhosted.org/packages/py3/i/idna/idna-3.7-py3-none-any.whl"
"$RUN" pip install idna >/dev/null
[ -f "$sd/idna/__init__.py" ]
