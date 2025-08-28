#!/usr/bin/env bash
set -Eeuox pipefail
set +H

for c in curl sed awk; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }; done
[ $# -ge 3 ] || { echo "usage: $0 owner/repo[@ref]|repo[@ref]|@ref|'' DEST [list|<pattern>] [<pattern> ...]" >&2; exit 2; }

DEFAULT_OWNER="Itexoft"
DEFAULT_REPO="DevOpsKit"
DEFAULT_REF="master"
API_ROOT="https://api.github.com"
RAW_ROOT="https://raw.githubusercontent.com"
UA="gh-pick.sh"

REPO_SPEC="$1"
DEST="$2"
shift 2

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
  REF_NAME="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: $UA" "$API_ROOT/repos/$OWNER/$REPO" | sed -n 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$REF_NAME" ] || REF_NAME="$DEFAULT_REF"
fi
[ -n "$OWNER" ] && [ -n "$REPO" ] && [ -n "$REF_NAME" ] || { echo "bad repo/ref" >&2; exit 2; }

INCLUDE=(); EXCLUDE=()
for p in "${PATTERNS[@]}"; do
  p="${p#/}"
  if [[ "$p" == \!* ]]; then EXCLUDE+=("${p:1}"); else INCLUDE+=("$p"); fi
done
[ ${#INCLUDE[@]} -gt 0 ] || INCLUDE+=("*")

has_wild() { [[ "$1" == *[\*\?[]* ]]; }
is_exact_file=0
if [ ${#INCLUDE[@]} -eq 1 ] && [ ${#EXCLUDE[@]} -eq 0 ] && ! has_wild "${INCLUDE[0]}"; then is_exact_file=1; fi

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

download_raw() {
  local path="$1" name out
  name="$(basename "$path")"
  [ "$DEST" = "-" ] && DEST="."
  mkdir -p "$DEST"
  out="$DEST/$name"
  curl -fsSL -H "User-Agent: $UA" "$RAW_ROOT/$OWNER/$REPO/$REF_NAME/$path" -o "$out"
}

if [ "$ACTION" = "get" ] && [ "$is_exact_file" -eq 1 ]; then
  f="${INCLUDE[0]}"
  download_raw "$f"
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

list_dir() {
  local path="$1"
  local url="https://api.github.com/repos/$OWNER/$REPO/contents"
  [ -n "$path" ] && url="$url/$path"
  url="$url?ref=$REF_NAME"
  curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: gh-pick.sh" "$url" \
  | awk 'BEGIN{RS="},"}{
      tp=""; pt="";
      if (match($0, /"type"[[:space:]]*:[[:space:]]*"([^"]+)"/, t)) tp=t[1];
      if (match($0, /"path"[[:space:]]*:[[:space:]]*"([^"]+)"/, m)) pt=m[1];
      if (pt!=""){ if(tp=="dir") print "dir|" pt; else if(tp=="file") print "file|" pt; }
    }'
}

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
  exit 0
fi

prefix="$(dirname "${SEL[0]}")"
while [ -n "$prefix" ] && [ "$prefix" != "." ]; do
  ok=1
  for r in "${SEL[@]}"; do case "$r" in "$prefix"/*) ;; *) ok=0; break ;; esac; done
  [ "$ok" -eq 1 ] && break
  new="${prefix%/*}"
  [ "$new" = "$prefix" ] && prefix="" || prefix="$new"
done

[ "$DEST" = "-" ] && DEST="."
mkdir -p "$DEST"

for r in "${SEL[@]}"; do
  rel="$r"
  if [ -n "$prefix" ] && [ "$prefix" != "." ]; then rel="${r#"$prefix/"}"; fi
  out="$DEST/$rel"
  mkdir -p "$(dirname "$out")"
  curl -fsSL -H "User-Agent: $UA" "$RAW_ROOT/$OWNER/$REPO/$REF_NAME/$r" -o "$out"
done