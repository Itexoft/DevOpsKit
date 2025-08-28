#!/usr/bin/env bash
set -Eeuo pipefail
"$RUN" install osxcross >/dev/null
"$RUN" install python 3.12 >/dev/null
"$RUN" install node 22 >/dev/null
"$RUN" true >/dev/null
[ -d "$OSX_ROOT/bin" ]
[ -d "$OSX_ROOT/env" ]
[ -d "$OSX_ROOT/shims" ]
[ -d "$OSX_ROOT/pkgs" ]
[ -d "$OSX_ROOT/wheelhouse" ]
count=$(find "$OSX_ROOT" -maxdepth 1 -type d -name 'site-*' | wc -l)
test "$count" -ge 1
vars=$(cut -d= -f1 "$OSX_ROOT/env/config.sh" | grep -v '^$')
uniq=$(printf '%s\n' "$vars" | sort | uniq -d)
[ -z "$uniq" ]
PATH="/usr/bin:/bin:foo:bar"
. "$OSX_ROOT/env/pathrc.sh"
first=$PATH
. "$OSX_ROOT/env/pathrc.sh"
second=${PATH%:}
[ "$second" = "$first" ]
grep find-links "$OSX_ROOT/env/pip-macos.conf" >/dev/null
grep target "$OSX_ROOT/env/pip-macos.conf" >/dev/null
