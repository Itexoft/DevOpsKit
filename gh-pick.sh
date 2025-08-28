#!/usr/bin/env bash
set -Eeuo pipefail
set +H
umask 077

for c in curl sed awk; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done
[ $# -ge 1 ] || { echo "usage: $0 owner/repo[@ref]|repo[@ref]|@ref|'' [DEST] [list|<pattern>] [<pattern> ...]" >&2; exit 2; }

DEFAULT_OWNER="Itexoft"
DEFAULT_REPO="devops"
DEFAULT_REF="master"
API_ROOT="https://api.github.com"
RAW_ROOT="https://raw.githubusercontent.com"
UA="gh-pick.sh"

LOG="$(mktemp)"
ok=0
cleanup_fail() { if [ "$ok" -ne 1 ]; then [ -s "$LOG" ] && cat "$LOG" >&2; fi; rm -f "$LOG"; }
trap cleanup_fail EXIT INT SIGTERM

has_wild() { [[ "$1" == *[\*\?[]* ]]; }
abs_path() { local p="$1"; local d b; d="$(cd "$(dirname "$p")" && pwd -P)"; b="$(basename "$p")"; printf '%s/%s\n' "$d" "$b"; }
is_shebang() { LC_ALL=C head -c 2 "$1" 2>/dev/null | LC_ALL=C grep -q '^#!'; }
is_exec_magic() {
  if command -v file >/dev/null 2>&1; then
    file -b "$1" 2>>"$LOG" | grep -qiE 'executable|Mach-O|PE32|PE32\+|ELF|script'
  else
    local h; h="$(LC_ALL=C head -c 4 "$1" 2>/dev/null | LC_ALL=C od -An -tx1 | tr -d ' \n')"
    [ "$h" = "7f454c46" ] || [ "$h" = "cffaedfe" ] || [ "$h" = "cefaedfe" ] || [ "$h" = "feedface" ] || [ "$h" = "feef04fe" ] || [ "${h:0:4}" = "4d5a" ]
  fi
}
mark_executable_if_needed() {
  local f="$1"
  if is_shebang "$f" || is_exec_magic "$f"; then chmod +x "$f" 2>>"$LOG" || true; fi
  if [ "$(uname -s)" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then xattr -d com.apple.quarantine "$f" >/dev/null 2>>"$LOG" || true; fi
}

REPO_SPEC="$1"; shift || true
DEST_GIVEN=0
if [ $# -ge 1 ]; then
  case "$1" in
    -|/*|./*|../*) DEST="$1"; DEST_GIVEN=1; shift ;;
    *) DEST="";;
  esac
else
  DEST=""
fi

ACTION="get"
if [ "${1:-}" = "list" ]; then ACTION="list"; shift; fi
[ $# -gt 0 ] || { echo "no patterns" >&2; exit 2; }

if [ $# -eq 1 ] && [[ "$1" == *" "* ]]; then read -r -a PATTERNS <<< "$1"; else PATTERNS=("$@"); fi

RAW="$REPO_SPEC"
REF=""
if [[ "$RAW" == *@* ]]; then REF="${RAW#*@}"; RAW="${RAW%@*}"; fi
if [[ "$RAW" == */* ]]; then OWNER="${RAW%%/*}"; REPO="${RAW##*/}"
elif [ -n "$RAW" ]; then OWNER="$DEFAULT_OWNER"; REPO="$RAW"
else OWNER="$DEFAULT_OWNER"; REPO="$DEFAULT_REPO"
fi

REF_NAME="$REF"
if [ -z "$REF_NAME" ]; then
  REF_NAME="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: $UA" "$API_ROOT/repos/$OWNER/$REPO" 2>>"$LOG" | sed -n 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$REF_NAME" ] || REF_NAME="$DEFAULT_REF"
fi
[ -n "$OWNER" ] && [ -n "$REPO" ] && [ -n "$REF_NAME" ] || { echo "bad repo/ref" >&2; exit 2; }

INCLUDE=(); EXCLUDE=()
for p in "${PATTERNS[@]}"; do
  p="${p#/}"
  if [[ "$p" == \!* ]]; then EXCLUDE+=("${p:1}"); else INCLUDE+=("$p"); fi
done
[ ${#INCLUDE[@]} -gt 0 ] || INCLUDE+=("*")

is_exact_file=0
if [ ${#INCLUDE[@]} -eq 1 ] && [ ${#EXCLUDE[@]} -eq 0 ] && ! has_wild "${INCLUDE[0]}"; then is_exact_file=1; fi

dest_root="$DEST"
TMP_ROOT_CREATED=0
if [ "$DEST_GIVEN" -eq 0 ]; then dest_root="$(mktemp -d)"; TMP_ROOT_CREATED=1; fi
[ "$dest_root" = "-" ] && dest_root="."
mkdir -p "$dest_root" 2>>"$LOG"

if [ "$TMP_ROOT_CREATED" -eq 1 ]; then
  ( p="$PPID"; d="$dest_root"; while kill -0 "$p" 2>/dev/null; do sleep 2; done; rm -rf "$d" >/dev/null 2>&1 || true ) >/dev/null 2>&1 &
fi

download_one() {
  local path="$1" out
  local name; name="$(basename "$path")"
  out="$dest_root/$name"
  curl -fsSL -H "User-Agent: $UA" "$RAW_ROOT/$OWNER/$REPO/$REF_NAME/$path" -o "$out" >>"$LOG" 2>&1
  mark_executable_if_needed "$out"
  abs_path "$out"
}

glob_re() {
  local p="$1"
  p="${p//\\/\\\\}"
  p="${p//./\\.}"
  p="${p//^/\\^}"
  p="${p//\$/\\$}"
  p="${p//+/\\+}"
  p="${p//(/\\(}"
  p="${p//)/\\)}"
  p="${p//|/\\|}"
  p="${p//[/\\[}"
  p="${p//]/\\]}"
  p="${p//\*\*/__DS__}"
  p="${p//\*/[^\/]*}"
  p="${p//__DS__/.*}"
  p="${p//\?/[^\\/]}"
  printf '^%s$' "$p"
}

list_dir() {
  local path="$1"
  local url="$API_ROOT/repos/$OWNER/$REPO/contents"
  [ -n "$path" ] && url="$url/$path"
  url="$url?ref=$REF_NAME"
  curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: $UA" "$url" 2>>"$LOG" \
  | awk 'BEGIN{RS="},"}{
      tp=""; pt="";
      if (match($0, /"type"[[:space:]]*:[[:space:]]*"([^"]+)"/, t)) tp=t[1];
      if (match($0, /"path"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) pt=m[1];
      if (pt!=""){ if(tp=="dir") print "dir|" pt; else if(tp=="file") print "file|" pt; }
    }'
}

if [ "$ACTION" = "get" ] && [ "$is_exact_file" -eq 1 ]; then
  f="${INCLUDE[0]}"
  p="$(download_one "$f")" || { echo "download failed: $f" >&2; exit 1; }
  printf '%s\n' "$p"
  ok=1
  exit 0
fi

base_dirs=()
seen=""
for p in "${INCLUDE[@]}"; do
  b="${p%%[*?[]*}"
  b="${b%/}"
  case ",$seen," in *,"$b",*) ;; *) base_dirs+=("$b"); seen="$seen,$b";; esac
done
[ ${#base_dirs[@]} -gt 0 ] || base_dirs+=("")

declare -a ALL_FILES=()
declare -a Q=()

for b in "${base_dirs[@]}"; do
  Q=("$b")
  while [ ${#Q[@]} -gt 0 ]; do
    d="${Q[0]}"; Q=("${Q[@]:1}")
    recs="$(list_dir "$d" || true)"
    [ -n "$recs" ] || continue
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      tp="${line%%|*}"; pt="${line#*|}"
      case "$tp" in
        dir) Q+=("$pt") ;;
        file) ALL_FILES+=("$pt") ;;
      esac
    done <<< "$recs"
  done
done

[ ${#ALL_FILES[@]} -gt 0 ] || { echo "no files in scope" >&2; exit 1; }

SEL=()
for r in "${ALL_FILES[@]}"; do
  inc=0
  for p in "${INCLUDE[@]}"; do re="$(glob_re "$p")"; [[ "$r" =~ $re ]] && { inc=1; break; }; done
  [ "$inc" -eq 1 ] || continue
  exc=0
  for p in "${EXCLUDE[@]}"; do re="$(glob_re "$p")"; [[ "$r" =~ $re ]] && { exc=1; break; }; done
  [ "$exc" -eq 0 ] && SEL+=("$r")
done

[ ${#SEL[@]} -gt 0 ] || { echo "no files matched" >&2; exit 1; }

if [ "$ACTION" = "list" ]; then
  for r in "${SEL[@]}"; do printf '%s\n' "$r"; done
  ok=1
  exit 0
fi

prefix="$(dirname "${SEL[0]}")"
while [ -n "$prefix" ] && [ "$prefix" != "." ]; do
  okp=1
  for r in "${SEL[@]}"; do case "$r" in "$prefix"/*) ;; *) okp=0; break ;; esac; done
  [ "$okp" -eq 1 ] && break
  new="${prefix%/*}"
  [ "$new" = "$prefix" ] && prefix="" || prefix="$new"
done

for r in "${SEL[@]}"; do
  rel="$r"
  if [ -n "$prefix" ] && [ "$prefix" != "." ]; then rel="${r#"$prefix/"}"; fi
  out="$dest_root/$rel"
  mkdir -p "$(dirname "$out")" 2>>"$LOG"
  curl -fsSL -H "User-Agent: $UA" "$RAW_ROOT/$OWNER/$REPO/$REF_NAME/$r" -o "$out" >>"$LOG" 2>&1
  mark_executable_if_needed "$out"
  printf '%s\n' "$(abs_path "$out")"
done

ok=1
exit 0