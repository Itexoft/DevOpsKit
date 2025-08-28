#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() { printf 'usage: %s <x509-pfx|pem|base64-file> <files...> [--password=<pass>]\n' "$0" >&2; exit 1; }

[ $# -ge 2 ] || usage

CERT_PATH="$1"; shift

PASS=""
FILES=()
while [ $# -gt 0 ]; do
  case "${1-}" in
    --password=*) PASS="${1#*=}"; shift;;
    --*) printf 'error: unknown option: %s\n' "$1" >&2; exit 1;;
    *) FILES+=("$1"); shift;;
  esac
done

[ ${#FILES[@]} -gt 0 ] || usage

die() { printf 'error: %s\n' "$1" >&2; exit "${2-1}"; }
warn() { printf 'warn: %s\n' "$1" >&2; }
info() { printf '%s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

resolve_abs() {
  local p="$1" dir base
  case "$p" in /*) ;; *) p="$(pwd -P)/$p" ;; esac
  dir="$(dirname "$p")"; base="$(basename "$p")"
  printf '%s/%s\n' "$(cd "$dir" >/dev/null 2>&1 && pwd -P)" "$base"
}

sanitize_pem_blocks() {
  awk 'BEGIN{skip=0}/-----BEGIN CERTIFICATE-----/{skip=1;next}/-----END CERTIFICATE-----/{skip=0;next}!skip{print}' "$1"
}

nuget_codes() {
  grep -Eo 'NU[0-9]{4}(:[^[:cntrl:]]*)?' "$1" | cut -c1-200 | sed 's/[[:space:]]\{2,\}/ /g' | sort -u | paste -sd, - | sed 's/,/, /g'
}

restore_keychains() {
  [ -n "${SECURITY_BIN-}" ] || return 0
  if [ -n "${KC_OLD_LIST-}" ]; then
    local arr=()
    while IFS= read -r line; do [ -n "$line" ] && arr+=("$line"); done <<< "$KC_OLD_LIST"
    if [ "${#arr[@]}" -gt 0 ]; then "$SECURITY_BIN" list-keychains -d user -s "${arr[@]}" >/dev/null 2>&1 || true; fi
  fi
  if [ -n "${KC_OLD_DEFAULT-}" ]; then "$SECURITY_BIN" default-keychain -d user -s "$KC_OLD_DEFAULT" >/dev/null 2>&1 || true; fi
}

tmp="$(mktemp -d)"
trap 'set +e; restore_keychains; if [ -n "${KC-}" ] && [ -n "${SECURITY_BIN-}" ]; then "$SECURITY_BIN" delete-keychain "$KC" >/dev/null 2>&1 || true; rm -f "$KC" >/dev/null 2>&1 || true; fi; rm -rf "$tmp" >/dev/null 2>&1 || true' EXIT INT SIGTERM

command -v curl >/dev/null 2>&1 || die "missing curl" 2

CERT_PATH="$(resolve_abs "$CERT_PATH")" && [ -f "$CERT_PATH" ] || die "certificate file not found: $CERT_PATH" 2

GHP="$tmp/gh-pick.sh" && curl -fsSL "https://raw.githubusercontent.com/Itexoft/devops/refs/heads/master/gh-pick.sh" -o "$GHP" && chmod +x "$GHP"
CCR="$("$GHP" "@master" "lib/cert-converter.sh")"
OSSC="$("$GHP" "@master" "utils/osx-arm64/osslsigncode")"

TS_PRIMARY="${TIMESTAMPER:-https://timestamp.digicert.com}"
TS_FALLBACK="${TIMESTAMPER_FALLBACK:-http://timestamp.sectigo.com}"
SIGN_SKIP_SIGNED="${SIGN_SKIP_SIGNED:-1}"

RC_SUCCESS=0
RC_FAILED=1
RC_SKIPPED=2

KEY_P12="$tmp/key.p12"

prepare_p12() {
  local src="$1"
  set +e
  "$CCR" "$src" pfx "$KEY_P12" "--password=$PASS" >/dev/null 2>&1
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    local content
    content="$(cat "$src" 2>/dev/null || true)"
    [ -n "$content" ] || die "unsupported certificate format; cannot read: $src"
    set +e
    "$CCR" "$content" pfx "$KEY_P12" "--password=$PASS" >/dev/null 2>&1
    rc=$?
    set -e
    [ $rc -eq 0 ] || die "unsupported certificate format; conversion failed"
  fi
  info "prepared PKCS#12"
}

prepare_p12 "$CERT_PATH"
[ -s "$KEY_P12" ] || die "invalid certificate: $CERT_PATH" 2

p12_cert_sha1() {
  local fp=""
  if have openssl; then
    if [ -n "${PASS-}" ]; then
      fp="$(openssl pkcs12 -in "$KEY_P12" -passin pass:"$PASS" -clcerts -nokeys 2>/dev/null | openssl x509 -noout -fingerprint -sha1 2>/dev/null | awk -F= '{gsub(":","",$2); print toupper($2)}' || true)"
    else
      fp="$(openssl pkcs12 -in "$KEY_P12" -passin pass: -clcerts -nokeys 2>/dev/null | openssl x509 -noout -fingerprint -sha1 2>/dev/null | awk -F= '{gsub(":","",$2); print toupper($2)}' || true)"
    fi
  fi
  printf '%s\n' "$fp"
}

p12_cert_algo() {
  local algo=""
  if have openssl; then
    if [ -n "${PASS-}" ]; then
      algo="$(openssl pkcs12 -in "$KEY_P12" -passin pass:"$PASS" -clcerts -nokeys 2>/dev/null | openssl x509 -noout -text 2>/dev/null | awk -F': *' '/Public Key Algorithm/ {print tolower($2); exit}' || true)"
    else
      algo="$(openssl pkcs12 -in "$KEY_P12" -passin pass: -clcerts -nokeys 2>/dev/null | openssl x509 -noout -text 2>/dev/null | awk -F': *' '/Public Key Algorithm/ {print tolower($2); exit}' || true)"
    fi
  fi
  case "$algo" in *rsa*) printf 'rsa\n';; *ec*|*ecdsa*) printf 'ec\n';; *) printf 'rsa\n';; esac
}

CERT_ALGO="$(p12_cert_algo || true)"

KC=""
KC_PW="$(openssl rand -hex 24 2>/dev/null | head -c 24 || echo 012345678901234567890123)"
CODESIGN_ID=""
KC_OLD_LIST=""
KC_OLD_DEFAULT=""
SYS_KC="/Library/Keychains/System.keychain"
ROOT_KC="/System/Library/Keychains/SystemRootCertificates.keychain"

SECURITY_BIN="$(command -v security || true)"
CODESIGN_BIN="$(command -v codesign || true)"

select_codesign_id_for() {
  local f="$1" cand
  [ -n "$SECURITY_BIN" ] && [ -n "$CODESIGN_BIN" ] || return 1
  local kcflag=()
  [ -n "$KC" ] && kcflag=(--keychain "$KC")
  while read -r cand; do
    [ -z "$cand" ] && continue
    if "$CODESIGN_BIN" --dryrun --force "${kcflag[@]}" --sign "$cand" "$f" >/dev/null 2>&1; then
      CODESIGN_ID="$cand"
      return 0
    fi
  done <<EOF
$("$SECURITY_BIN" find-identity -p basic -v "$KC" 2>/dev/null | awk '/[0-9A-F]{40}/ {print $2}')
EOF
  while read -r cand; do
    [ -z "$cand" ] && continue
    if "$CODESIGN_BIN" --dryrun --force "${kcflag[@]}" --sign "$cand" "$f" >/dev/null 2>&1; then
      CODESIGN_ID="$cand"
      return 0
    fi
  done <<EOF
$("$SECURITY_BIN" find-certificate -a -Z "$KC" 2>/dev/null | awk '/SHA-1 hash:/ {print $3}')
EOF
  return 1
}

codesign_setup() {
  [ -n "$SECURITY_BIN" ] && [ -n "$CODESIGN_BIN" ] || return 1
  KC="$tmp/codesign.keychain-db"
  "$SECURITY_BIN" create-keychain -p "$KC_PW" "$KC" >/dev/null
  "$SECURITY_BIN" unlock-keychain -p "$KC_PW" "$KC" >/dev/null
  local -a args=(-q import "$KEY_P12" -k "$KC" -A -T "$CODESIGN_BIN")
  if [ -n "${PASS+x}" ]; then args+=(-P "$PASS"); else args+=(-P ""); fi
  "$SECURITY_BIN" "${args[@]}" </dev/null >/dev/null 2>&1 || return 1
  "$SECURITY_BIN" set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PW" "$KC" >/dev/null 2>&1 || true
  KC_OLD_LIST="$("$SECURITY_BIN" list-keychains -d user 2>/dev/null | sed -E 's/^ *"([^"]+)".*$/\1/')"
  KC_OLD_DEFAULT="$("$SECURITY_BIN" default-keychain -d user 2>/dev/null | sed -E 's/^.*"([^"]+)".*$/\1/')"
  "$SECURITY_BIN" list-keychains -d user -s "$KC" "$SYS_KC" "$ROOT_KC" >/dev/null 2>&1 || true
  "$SECURITY_BIN" default-keychain -d user -s "$KC" >/dev/null 2>&1 || true
  CODESIGN_ID="$("$SECURITY_BIN" find-identity -p codesigning -v "$KC" 2>/dev/null | awk '/[0-9A-F]{40}/ {print $2; exit}')"
  return 0
}

sign_pe_with_ossl() {
  local f="$1" out="$tmp/$(basename "$f").signed"
  have "$OSSC" || return 1

  local -a cmd=("$OSSC" sign -pkcs12 "$KEY_P12")
  [ -n "${PASS-}" ] && cmd+=(-pass "$PASS")
  cmd+=(-in "$f" -out "$out" -t "$TS_PRIMARY")
  local ts_pos=$(( ${#cmd[@]} - 1 ))

  if "${cmd[@]}" >/dev/null 2>&1; then
    :
  else
    cmd[$ts_pos]="$TS_FALLBACK"
    "${cmd[@]}" >/dev/null 2>&1 || return 1
  fi

  mv -f "$out" "$f"
  "$OSSC" verify -in "$f" >/dev/null 2>&1 || true
  return 0
}

macho_prev_info() {
  [ -n "$CODESIGN_BIN" ] || { printf '\n'; return 0; }
  local out info
  out="$("$CODESIGN_BIN" -dv --verbose=2 "$1" 2>&1 || true)"
  if printf '%s\n' "$out" | grep -qi 'Signature=adhoc'; then printf 'adhoc\n'; return 0; fi
  info="$(printf '%s\n' "$out" | awk -F'= *' '/^Authority=/{print $2}')"
  if [ -n "$info" ]; then printf '%s\n' "$(printf '%s' "$info" | paste -sd' | ' -)"; else printf '\n'; fi
}

is_signed_macho() {
  [ -n "$CODESIGN_BIN" ] || return 1
  local out
  out="$("$CODESIGN_BIN" -dv --verbose=2 "$1" 2>&1 || true)"
  printf '%s\n' "$out" | grep -qi '^Authority=' || return 1
  printf '%s\n' "$out" | grep -qi 'Signature=adhoc' && return 1
  return 0
}

is_signed_pe() {
  if have "$OSSC"; then
    "$OSSC" verify -in "$1" >/dev/null 2>&1 && return 0
  fi
  return 1
}

nupkg_has_signature() {
  local f="$1"
  if have unzip; then
    unzip -Z1 "$f" 2>/dev/null | grep -qx '.signature.p7s'
  elif have zipinfo; then
    zipinfo -1 "$f" 2>/dev/null | grep -qx '.signature.p7s'
  else
    return 1
  fi
}

sign_macho() {
  local f="$1" prev prev_kind="none"
  [ -n "$CODESIGN_BIN" ] || { warn "skipped: $f (codesign not available)"; return $RC_SKIPPED; }
  if [ -z "$KC" ]; then codesign_setup || true; fi
  local kcflag=()
  [ -n "$KC" ] && kcflag=(--keychain "$KC")

  prev="$(macho_prev_info "$f" || true)"
  if [ "$prev" = "adhoc" ]; then prev_kind="adhoc"; elif [ -n "$prev" ]; then prev_kind="proper"; else prev_kind="none"; fi
  if [ "${SIGN_SKIP_SIGNED:-1}" != "0" ] && [ "$prev_kind" = "proper" ]; then info "already signed: $f; previous: $prev"; return $RC_SUCCESS; fi

  [ -n "$CODESIGN_ID" ] || select_codesign_id_for "$f" || true

  if [ -n "$CODESIGN_ID" ] && "$CODESIGN_BIN" --force --timestamp --options runtime "${kcflag[@]}" --sign "$CODESIGN_ID" "$f" >/dev/null 2>&1; then
    if [ "$prev_kind" = "adhoc" ]; then info "resigned: $f (replaced adhoc)"; elif [ "$prev_kind" = "proper" ]; then info "resigned: $f (previous: $prev)"; else info "signed: $f"; fi
    "$CODESIGN_BIN" --verify --deep --strict "$f" >/dev/null 2>&1 || { warn "verify failed: $f"; return $RC_FAILED; }
    info "verified: codesign $f"
    return $RC_SUCCESS
  fi

  if "$CODESIGN_BIN" --force --timestamp --options runtime "${kcflag[@]}" --sign - "$f" >/dev/null 2>&1; then
    if [ "$prev_kind" = "adhoc" ]; then info "resigned: $f (adhoc fallback)"; else info "signed: $f (adhoc)"; fi
    "$CODESIGN_BIN" --verify --deep --strict "$f" >/dev/null 2>&1 || true
    info "verified: codesign $f"
    return $RC_SUCCESS
  fi

  warn "failed: $f (codesign)"
  return $RC_FAILED
}


sign_pe() {
  local f="$1" was=0
  if is_signed_pe "$f"; then was=1; fi
  if [ "${SIGN_SKIP_SIGNED:-1}" != "0" ] && [ $was -eq 1 ]; then info "already signed: $f"; return $RC_SUCCESS; fi
  if ! have "$OSSC"; then
    warn "skipped: $f (no PE signer available)"
    return $RC_SKIPPED
  fi
  if sign_pe_with_ossl "$f"; then
    if [ $was -eq 1 ]; then info "resigned: $f"; else info "signed: $f"; fi
    if is_signed_pe "$f"; then info "verified: authenticode $f"; fi
    return $RC_SUCCESS
  fi
  warn "failed: $f (authenticode)"
  return $RC_FAILED
}

sign_nupkg() {
  local f="$1" was=0
  have dotnet || { warn "skipped: $f (dotnet not found)"; return $RC_SKIPPED; }
  [ "$CERT_ALGO" = "rsa" ] || { warn "skipped: $f (NuGet requires RSA; certificate algorithm: $CERT_ALGO)"; return $RC_SKIPPED; }

  if nupkg_has_signature "$f"; then was=1; else was=0; fi

  local log="$tmp/nuget.$(basename "$f").log"
  local base=(nuget sign "$f" --certificate-path "$KEY_P12")
  [ -n "${PASS-}" ] && base+=(--certificate-password "$PASS")
  local sign_ok=0

  if DOTNET_CLI_UI_LANGUAGE=en dotnet "${base[@]}" --timestamper "$TS_PRIMARY" -v minimal >"$log" 2>&1; then sign_ok=1;
  elif DOTNET_CLI_UI_LANGUAGE=en dotnet "${base[@]}" --timestamper "$TS_FALLBACK" -v minimal >"$log" 2>&1; then sign_ok=1;
  elif DOTNET_CLI_UI_LANGUAGE=en dotnet "${base[@]}" --timestamper "$TS_PRIMARY" --overwrite -v minimal >"$log" 2>&1; then sign_ok=1;
  elif DOTNET_CLI_UI_LANGUAGE=en dotnet "${base[@]}" --timestamper "$TS_FALLBACK" --overwrite -v minimal >"$log" 2>&1; then sign_ok=1;
  else sign_ok=0;
  fi

  local verify_log="$tmp/nuget.verify.$(basename "$f").log"
  local verify_rc=0
  DOTNET_CLI_UI_LANGUAGE=en dotnet nuget verify "$f" --all -v minimal >"$verify_log" 2>&1 || verify_rc=$?

  local codes_sign codes_verify codes_all sig_present=0
  codes_sign="$(nuget_codes "$log" || true)"
  codes_verify="$(nuget_codes "$verify_log" || true)"
  if [ -n "$codes_sign" ] && [ -n "$codes_verify" ]; then codes_all="$codes_sign, $codes_verify"; else codes_all="$codes_sign$codes_verify"; fi
  codes_all="$(printf '%s' "$codes_all" | sed 's/, \+/,/g')"

  if nupkg_has_signature "$f"; then sig_present=1; fi

  if [ $sign_ok -eq 1 ] && [ $verify_rc -eq 0 ]; then
    if [ $was -eq 1 ]; then info "resigned: $f"; else info "signed: $f"; fi
    info "verified: nuget $f"
    return $RC_SUCCESS
  fi

  if [ $sig_present -eq 1 ] || [ $sign_ok -eq 1 ]; then
    local allow=1
    if [ -n "$codes_all" ]; then
      while IFS= read -r code; do
        [ -z "$code" ] && continue
        code="${code%%:*}"
        case "$code" in NU3018|NU3042) ;; *) allow=0; break;; esac
      done <<EOF
$(printf '%s' "$codes_all" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
EOF
    fi
    if [ $allow -eq 1 ]; then
      if [ $was -eq 1 ]; then info "resigned: $f"; else info "signed: $f"; fi
      [ -n "$codes_all" ] && warn "nuget verify issues: $codes_all"
      return $RC_SUCCESS
    fi
  fi

  warn "failed: $f (nuget sign)"
  [ -n "$codes_all" ] && warn "nuget sign codes: $codes_all"
  return $RC_FAILED
}

success=0
failed=0
skipped=0

for x in "${FILES[@]}"; do
  p="$(resolve_abs "$x")"
  [ -e "$p" ] || { warn "missing: $p"; failed=$((failed+1)); continue; }
  ext="$(printf '%s' "${p##*.}" | tr '[:upper:]' '[:lower:]')"
  rc=0
  case "$ext" in
    nupkg)
      if sign_nupkg "$p"; then rc=$RC_SUCCESS; else rc=$?; fi
    ;;
    dylib)
      if sign_macho "$p"; then rc=$RC_SUCCESS; else rc=$?; fi
    ;;
    dll|exe|msi|msix|appx|msp|msm|cab|cat)
      if sign_pe "$p"; then rc=$RC_SUCCESS; else rc=$?; fi
    ;;
    *)
      if have file && file -b "$p" 2>/dev/null | grep -qi 'mach-o'; then
        if sign_macho "$p"; then rc=$RC_SUCCESS; else rc=$?; fi
      elif have file && file -b "$p" 2>/dev/null | grep -qi 'pe32'; then
        if sign_pe "$p"; then rc=$RC_SUCCESS; else rc=$?; fi
      elif [ "$ext" = "nupkg" ]; then
        if sign_nupkg "$p"; then rc=$RC_SUCCESS; else rc=$?; fi
      else
        warn "skipped: $p (unknown format)"
        skipped=$((skipped+1))
        continue
      fi
    ;;
  esac
  case "$rc" in
    $RC_SUCCESS) success=$((success+1));;
    $RC_SKIPPED) skipped=$((skipped+1));;
    *) failed=$((failed+1));;
  esac
done

info "success: $success, failed: $failed, skipped: $skipped"

[ "$failed" -eq 0 ] || exit 1
exit 0