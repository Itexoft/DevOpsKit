#!/usr/bin/env bash
set -Eeuo pipefail
"$RUN" install python 3.12 >/dev/null
"$RUN" python -c 'import sys;print(sys.version)' | grep -q '^3\.12\.'
mkdir -p "$OSX_ROOT/pkgs/python/3.11.0/bin"
printf '#!/usr/bin/env bash\n' > "$OSX_ROOT/pkgs/python/3.11.0/bin/python3"
chmod +x "$OSX_ROOT/pkgs/python/3.11.0/bin/python3"
ln -sf "$OSX_ROOT/pkgs/python/3.11.0/bin/python3" "$OSX_ROOT/pkgs/python/3.11.0/bin/python"
"$RUN" install python 3.11.0 >/dev/null
[ "$(readlink -f "$OSX_ROOT/pkgs/python/current")" = "$OSX_ROOT/pkgs/python/3.11.0" ]
grep -q "$OSX_ROOT/site-" "$OSX_ROOT/env/pip-macos.conf"
