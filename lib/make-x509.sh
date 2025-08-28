#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

read_req() { local p v; p="$1"; while :; do printf '%s: ' "$p" >&2; IFS= read -r v </dev/tty || exit 1; [ -n "${v// }" ] && { printf '%s' "$v"; return 0; }; done; }
read_opt() { local p v; p="$1"; printf '%s: ' "$p" >&2; IFS= read -r v </dev/tty || exit 1; printf '%s' "$v"; }
read_def() { local p d v; p="$1"; d="$2"; printf '%s [%s]: ' "$p" "$d" >&2; IFS= read -r v </dev/tty || exit 1; [ -n "${v// }" ] && printf '%s' "$v" || printf '%s' "$d"; }

CN="$(read_req 'Common Name (CN)')"
O="$(read_opt 'Organization (O)')"
OU="$(read_opt 'Organizational Unit (OU)')"
C="$(read_opt 'Country (C, 2 letters)')"
ST="$(read_opt 'State/Province (ST)')"
L="$(read_opt 'Locality/City (L)')"
EMAIL="$(read_opt 'Email')"
SANS="$(read_opt 'SubjectAltName entries (comma, e.g. DNS:example.com,IP:127.0.0.1)')"
END_SEC="$(date -u -j -f '%Y-%m-%d %H:%M:%S' '2049-12-31 23:59:59' +%s)"
NOW_SEC="$(date -u +%s)"
if [ "$END_SEC" -le "$NOW_SEC" ]; then MAX_DAYS=1; else MAX_DAYS=$(( (END_SEC - NOW_SEC) / 86400 )); fi
DAYS="$(read_def 'Validity in days' "$MAX_DAYS")"
case "$DAYS" in
  ''|*[!0-9]* ) DAYS="$MAX_DAYS" ;;
  * ) [ "$DAYS" -gt "$MAX_DAYS" ] && DAYS="$MAX_DAYS"; [ "$DAYS" -le 0 ] && DAYS="$MAX_DAYS" ;;
esac
KT="$(read_def 'Key type (rsa|ecdsa)' 'rsa')"
KS="$( [ "$KT" = "rsa" ] && read_def 'RSA bits' '3072' || read_def 'ECDSA curve' 'prime256v1')"

printf 'PFX password (empty allowed): ' >&2
TTY_STATE="$(stty -g </dev/tty 2>/dev/null || true)"
TMP="$(mktemp -d)"
trap '{ [ -n "${TTY_STATE-}" ] && stty "$TTY_STATE" </dev/tty 2>/dev/null || true; rm -rf "$TMP"; }' EXIT INT SIGTERM
stty -echo </dev/tty
IFS= read -r PFXPW </dev/tty || true
stty echo </dev/tty
printf '\n' >&2

BASE="$(printf '%s' "$CN" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
[ -n "$BASE" ] || BASE="cert"

NSANS=""
if [ -n "$SANS" ]; then
  IFS=',' read -ra _arr <<<"$SANS"
  for e in "${_arr[@]}"; do
    e="${e//[[:space:]]/}"
    [ -z "$e" ] && continue
    if [[ "$e" =~ ^(DNS|IP|URI|email|RID|dirName|otherName): ]]; then
      val="$e"
    elif [[ "$e" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
      val="URI:$e"
    elif [[ "$e" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      val="IP:$e"
    elif [[ "$e" == *:* ]]; then
      val="IP:$e"
    elif [[ "$e" == *"@"* ]]; then
      val="email:$e"
    else
      val="DNS:$e"
    fi
    if [ -z "$NSANS" ]; then NSANS="$val"; else NSANS="$NSANS,$val"; fi
  done
fi

CFG="$TMP/openssl.cnf"
{
  printf '%s\n' '[req]'
  printf '%s\n' 'distinguished_name=dn' 'prompt=no' 'req_extensions=req_ext'
  printf '%s\n' '[dn]'
  [ -n "$C" ] && printf 'C=%s\n' "$C"
  [ -n "$ST" ] && printf 'ST=%s\n' "$ST"
  [ -n "$L" ] && printf 'L=%s\n' "$L"
  [ -n "$O" ] && printf 'O=%s\n' "$O"
  [ -n "$OU" ] && printf 'OU=%s\n' "$OU"
  printf 'CN=%s\n' "$CN"
  [ -n "$EMAIL" ] && printf 'emailAddress=%s\n' "$EMAIL"
  printf '%s\n' '[req_ext]'
  printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature' 'extendedKeyUsage=codeSigning'
  [ -n "$NSANS" ] && printf 'subjectAltName=%s\n' "$NSANS"
  printf '%s\n' '[v3_codesign]'
  printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature' 'extendedKeyUsage=codeSigning'
  [ -n "$NSANS" ] && printf 'subjectAltName=%s\n' "$NSANS"
} >"$CFG"

KEY="$SCRIPT_DIR/$BASE.key.pem"
CRT="$SCRIPT_DIR/$BASE.cert.pem"
P12="$SCRIPT_DIR/$BASE.p12"
B64="$SCRIPT_DIR/$BASE.p12.base64.txt"

if [ "$KT" = "rsa" ]; then
  openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$KS" -out "$KEY"
else
  openssl ecparam -name "$KS" -genkey -noout -out "$KEY"
fi

SUBJ="/CN=$CN"
[ -n "$O" ] && SUBJ="$SUBJ/O=$O"
[ -n "$OU" ] && SUBJ="$SUBJ/OU=$OU"
[ -n "$C" ] && SUBJ="$SUBJ/C=$C"
[ -n "$ST" ] && SUBJ="$SUBJ/ST=$ST"
[ -n "$L" ] && SUBJ="$SUBJ/L=$L"
[ -n "$EMAIL" ] && SUBJ="$SUBJ/emailAddress=$EMAIL"

CSR="$TMP/req.csr"
openssl req -new -key "$KEY" -subj "$SUBJ" -config "$CFG" -reqexts req_ext -out "$CSR"
openssl x509 -req -in "$CSR" -signkey "$KEY" -days "$DAYS" -extfile "$CFG" -extensions v3_codesign -sha256 -out "$CRT"

if [ -n "${PFXPW-}" ]; then
  openssl pkcs12 -export -inkey "$KEY" -in "$CRT" -out "$P12" -name "$CN" -passout pass:"$PFXPW"
else
  openssl pkcs12 -export -inkey "$KEY" -in "$CRT" -out "$P12" -name "$CN" -passout pass:
fi

base64 < "$P12" > "$B64"

printf 'written: %s\n' "$KEY"
printf 'written: %s\n' "$CRT"
printf 'written: %s\n' "$P12"
printf 'written: %s\n' "$B64"