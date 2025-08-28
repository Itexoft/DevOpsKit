#!/usr/bin/env bash
set -Eeuo pipefail
. "$OSX_ROOT/env/config.sh"
"$RUN" install osxcross >/dev/null
cat > hello.c <<'EOC'
int main(){return 0;}
EOC
"$RUN" env | grep -q "CC=xcrun clang"
"$RUN" env | grep -q "CXX=xcrun clang++"
"$RUN" env | grep -q "CFLAGS=.*-mmacos-version-min=$DEFAULT_DEPLOY_MIN"
"$RUN" env | grep -q "CXXFLAGS=.*-stdlib=libc++ -mmacos-version-min=$DEFAULT_DEPLOY_MIN"
"$RUN" env | grep -q "LDFLAGS=.*-stdlib=libc++"
"$RUN" sh -c "clang \$CFLAGS hello.c -o hello \$LDFLAGS"
file hello | grep -qi 'Mach-O'
