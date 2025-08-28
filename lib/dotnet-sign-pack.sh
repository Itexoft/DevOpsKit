#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

cert="${SIGN_CERT-}"
pass="${SIGN_PASSWORD-}"
args=()
outdir=""

while [ $# -gt 0 ]; do
  case "${1-}" in
    --cert=*) cert="${1#*=}"; [ -z "$cert" ] && { echo "missing value for --cert" >&2; exit 2; }; shift;;
    --password=*) pass="${1#*=}"; shift;;
    -o|--output) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; outdir="$2"; args+=("$1" "$2"); shift 2;;
    -o=*|--output=*) v="${1#*=}"; outdir="$v"; args+=("$1"); shift;;
    *) args+=("$1"); shift;;
  esac
done

[ ${#args[@]} -ge 1 ] || { echo "usage: dotnet-sign-pack.sh [dotnet pack args or *.nupkg ...] [--cert X509] [--password=PASS]" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "missing curl" >&2; exit 2; }
command -v unzip >/dev/null 2>&1 || { echo "missing unzip" >&2; exit 2; }
command -v zip   >/dev/null 2>&1 || { echo "missing zip" >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }
die() { printf 'error: %s\n' "$1" >&2; [ -n "${ERR-}" ] && [ -s "$ERR" ] && cat "$ERR" >&2; exit "${2-1}"; }
warn() { printf 'warn: %s\n' "$1" >&2; }
info() { printf '%s\n' "$1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT SIGTERM
ERR="$tmp/err.txt"; : >"$ERR"

GH="$tmp/gh-pick.sh" && curl -fsSL "https://raw.githubusercontent.com/Itexoft/devops/refs/heads/master/gh-pick.sh" -o "$GH" && chmod +x "$GH"
CCR="$("$GH" "@master" "lib/cert-converter.sh")"

SIGN="" && if [ -n "${cert// }" ]; then p="$("$GH" "@master" "lib/sign-tool.sh")"; [ -n "$p" ] || die "gh-pick failed: sign-tool.sh"; SIGN="$p"; fi

TS_PRIMARY="${TIMESTAMPER:-https://timestamp.digicert.com}"
TS_FALLBACK="${TIMESTAMPER_FALLBACK:-http://timestamp.sectigo.com}"

nuget_codes() { grep -Eo 'NU[0-9]{4}(:[^[:cntrl:]]*)?' "$1" | cut -c1-200 | sed 's/[[:space:]]\{2,\}/ /g' | sort -u | paste -sd, - | sed 's/,/, /g'; }

certfile=""
if [ -n "${cert// }" ]; then
  certfile="$tmp/cert.input"
  if [ -f "$cert" ]; then cp "$cert" "$certfile"; else printf '%s' "$cert" >"$certfile"; fi
  chmod 600 "$certfile"
fi

PFX=""
if [ -n "${cert// }" ]; then
  PFX="$tmp/cert.pfx"
  cmd=( "$CCR" "$certfile" pfx "$PFX" )
  [ -n "$pass" ] && cmd+=( "--password=$pass" )
  "${cmd[@]}" >/dev/null 2>&1 || die "certificate conversion to PFX failed"
  [ -s "$PFX" ] || die "empty PFX produced"
fi

is_nupkg_arg=0
for a in "${args[@]}"; do case "$a" in *.nupkg) is_nupkg_arg=1;; esac; done

stamp="$tmp/stamp"; : >"$stamp"
nupkgs=()

if [ "$is_nupkg_arg" -eq 1 ]; then
  for a in "${args[@]}"; do [ -f "$a" ] && nupkgs+=("$(cd "$(dirname "$a")" && pwd -P)/$(basename "$a")"); done
else
  command -v dotnet >/dev/null 2>&1 || die "missing dotnet"
  DOTNET_CLI_UI_LANGUAGE=en dotnet pack "${args[@]}" 2>>"$ERR" || die "dotnet pack failed"
  searchdir="."
  [ -n "$outdir" ] && searchdir="$outdir"
  while IFS= read -r -d '' f; do nupkgs+=("$f"); done < <(find "$searchdir" -type f -name '*.nupkg' -newer "$stamp" -print0 2>/dev/null || true)
  if [ "${#nupkgs[@]}" -eq 0 ]; then
    while IFS= read -r -d '' f; do nupkgs+=("$f"); done < <(find "$searchdir" -type f -name '*.nupkg' -print0 2>/dev/null || true)
  fi
fi

[ "${#nupkgs[@]}" -gt 0 ] || die "no .nupkg found"

repack_sign_nupkg() {
  local pkg="$1"
  local work="$tmp/$(basename "$pkg").work"
  rm -rf "$work"
  mkdir -p "$work/u"
  unzip -q "$pkg" -d "$work/u" 2>>"$ERR" || { warn "unzip failed: $pkg"; return 1; }

  local list="$work/.targets.all"
  : >"$list"

  if have file; then
    find "$work/u" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
      local t; t="$(file -b "$f" 2>>"$ERR" || true)"
      printf '%s\n' "$t" | grep -qiE 'mach-o|pe32' && printf '%s\n' "$f" >>"$list"
    done
  fi

  find "$work/u" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.dylib' -o -name '*.so' -o -name '*.msi' -o -name '*.msix' -o -name '*.appx' -o -name '*.msp' -o -name '*.msm' -o -name '*.cab' -o -name '*.cat' \) -print 2>/dev/null >>"$list" || true

  local uniq="$work/.targets.uniq"
  awk '!seen[$0]++' "$list" >"$uniq" 2>>"$ERR" || true

  local targets=()
  while IFS= read -r f; do [ -n "$f" ] && targets+=("$f"); done < "$uniq"

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "nupkg content: no signable binaries in $pkg"
    return 0
  fi

  echo "nupkg content: signing ${#targets[@]} files in $pkg"

  "$SIGN" "$PFX" "${targets[@]}" "--password=$pass" || return 1

  local newpkg="$work/$(basename "$pkg").new"
  (cd "$work/u" && find . -mindepth 1 -maxdepth 1 -print | sed 's|^\./||' | zip -q -r "$newpkg" -@) 2>>"$ERR" || { warn "zip repack failed: $pkg"; return 1; }
  mv -f "$newpkg" "$pkg" 2>>"$ERR" || { warn "zip replace failed: $pkg"; return 1; }
  echo "nupkg content: updated $pkg"
  return 0
}

signed=0 failed=0 skipped=0
for p in "${nupkgs[@]}"; do
  [ -f "$p" ] || { warn "missing nupkg: $p"; failed=$((failed+1)); continue; }
  if [ -n "${cert// }" ]; then repack_sign_nupkg "$p" || true; fi
#  if [ -n "${cert// }" ]; then
#    if "$SIGN" "$PFX" "$p" "--password=$pass"; then signed=$((signed+1)); else failed=$((failed+1)); fi
#  else
#    skipped=$((skipped+1))
#    warn "skipped nuget sign (no cert provided): $p"
#  fi
done

info "summary: signed=$signed failed=$failed skipped=$skipped"
exit $([ "$failed" -gt 0 ] && echo 2 || echo 0)