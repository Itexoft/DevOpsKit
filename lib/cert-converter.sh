#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() { printf 'usage: %s <input|-> <outfmt: pem|pfx|snk|--pem|--pfx|--snk> <output> [--base64] [--password=<pass>]\n' "$(basename "$0")" >&2; exit 1; }

[ $# -ge 3 ] || usage

have() { command -v "$1" >/dev/null 2>&1; }
die() { printf 'error: %s\n' "$1" >&2; [ -n "${ERR-}" ] && [ -s "$ERR" ] && cat "$ERR" >&2; exit "${2-1}"; }
warn() { printf 'warn: %s\n' "$1" >&2; }
info() { printf '%s\n' "$1"; }

have openssl || die "openssl not found"

IN_SPEC="$1"; shift
FMT="$(printf '%s' "$1" | sed 's/^--//')"; shift
OUT_PATH="$1"; shift

B64_OUT=0
PASS="${PASS-}"

while [ $# -gt 0 ]; do
  case "${1-}" in
    --base64) B64_OUT=1; shift ;;
    --password=*) PASS="${1#*=}"; shift;;
    *) usage ;;
  esac
done

[ -n "$FMT" ] || usage
case "$FMT" in pem|pfx|snk) ;; *) usage ;; esac

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT INT SIGTERM

ERR="$tmp/err.txt"; : >"$ERR"

b64_decode_file() {
  local in="$1" out="$2" norm="$tmp/b64.norm" len mod
  : >"$out"
  : >"$norm"
  if have base64; then
    base64 --decode "$in" >"$out" 2>/dev/null; [ -s "$out" ] && return 0
    base64 -d "$in" >"$out" 2>/dev/null; [ -s "$out" ] && return 0
    base64 -D -i "$in" -o "$out" 2>/dev/null; [ -s "$out" ] && return 0
  fi
  LC_ALL=C tr -d '\r\n \t' <"$in" | LC_ALL=C tr '_-' '/+' >"$norm" || return 1
  len="$(LC_ALL=C wc -c <"$norm" | tr -d '[:space:]')"
  mod=$(( len % 4 ))
  if [ "$mod" -eq 2 ]; then printf '==' >>"$norm"; elif [ "$mod" -eq 3 ]; then printf '=' >>"$norm"; fi
  openssl base64 -d -A -in "$norm" -out "$out" >/dev/null 2>&1
  [ -s "$out" ]
}

b64_decode_str() {
  local s="$1" out="$2" n n2 m
  : >"$out"
  case "$s" in
    data:*) s="${s#*,}";;
  esac
  n="$(printf '%s' "$s" | LC_ALL=C tr -d '\r\n \t')"
  if have base64; then
    printf '%s' "$n" | base64 --decode >"$out" 2>/dev/null; [ -s "$out" ] && return 0
    printf '%s' "$n" | base64 -d >"$out" 2>/dev/null; [ -s "$out" ] && return 0
  fi
  n2="$(printf '%s' "$n" | LC_ALL=C tr '_-' '/+')"
  m=$(( ${#n2} % 4 ))
  if [ $m -eq 2 ]; then n2="${n2}=="; elif [ $m -eq 3 ]; then n2="${n2}="; fi
  if have base64; then
    printf '%s' "$n2" | base64 --decode >"$out" 2>/dev/null; [ -s "$out" ] && return 0
    printf '%s' "$n2" | base64 -d >"$out" 2>/dev/null; [ -s "$out" ] && return 0
  fi
  printf '%s' "$n2" | openssl base64 -d -A -out "$out" >/dev/null 2>&1
  [ -s "$out" ]
}

b64_encode_file() {
  local in="$1" out="$2"
  if have base64; then
    base64 -w0 <"$in" >"$out" 2>/dev/null || { base64 <"$in" | tr -d '\n' >"$out"; }
  else
    openssl base64 -A -in "$in" -out "$out" >/dev/null 2>&1
  fi
}

is_snk() {
  if rsa_supports_msblob; then
    openssl rsa -inform MSBLOB -in "$1" -noout -modulus >/dev/null 2>&1 && return 0 || return 1
  fi
  ensure_dotnet_snk_tool || return 1
  local t="$tmp/.snkprobe.pem"
  dotnet "$SNK_TOOL" snk2pem "$1" "$t" >/dev/null 2>&1 && [ -s "$t" ]
}
is_der_cert() { openssl x509 -inform DER -in "$1" -noout >/dev/null 2>&1; }
is_pem() { LC_ALL=C head -c 2048 "$1" 2>/dev/null | grep -m1 -q -- '-----BEGIN '; }
pem_has_key() { grep -q -- '^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' "$1"; }
pem_has_cert() { grep -q -- '^-----BEGIN CERTIFICATE-----' "$1"; }
is_der_key() {
  openssl pkcs8 -inform DER -in "$1" -nocrypt -noout >/dev/null 2>&1 && return 0
  openssl rsa -inform DER -in "$1" -noout -modulus >/dev/null 2>&1 && return 0
  return 1
}

pkcs12_legacy_opt() {
  local h="$(openssl pkcs12 -help 2>&1 || true)"
  case "$h" in
    *-legacy*) printf -- '-legacy' ;;
  esac
  return 0
}

openssl_pkcs12_probe() {
  local f="$1" pw="$2" log="$tmp/p12.probe.$RANDOM.txt" opt
  : >"$log"
  opt="$(pkcs12_legacy_opt)"
  if [ -n "$pw" ]; then
    openssl pkcs12 $opt -in "$f" -passin pass:"$pw" -noout -info >"$log" 2>&1 && return 0
  fi
  openssl pkcs12 $opt -in "$f" -passin pass: -noout -info >"$log" 2>&1 && return 0
  LC_ALL=C grep -Eiq 'mac verify|invalid password|bad decrypt|password.+required' "$log" && return 0
  if LC_ALL=C openssl asn1parse -inform DER -in "$f" -i 2>>"$log" | grep -Eiq '1\.2\.840\.113549\.1\.12|pkcs7'; then return 0; fi
  return 1
}

ensure_dotnet_snk_tool() {
  [ -n "${SNK_TOOL-}" ] && [ -s "$SNK_TOOL" ] && return 0
  : >"$ERR"
  have dotnet || { printf 'dotnet not found\n' >"$ERR"; return 1; }
  local dir="$tmp/dn_snk"
  rm -rf "$dir"
  mkdir -p "$dir"
  dotnet new console -n snktool -o "$dir" -f net8.0 --force >/dev/null 2>"$ERR" || return 1
  cat >"$dir/Program.cs"<<'CS'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

class P {
  static int Main(string[] a) {
    if (a.Length < 3) { Console.Error.WriteLine("args: <cmd> <in> <out> [password]"); return 2; }
    var cmd=a[0]; var i=a[1]; var o=a[2]; var pw=a.Length>=4?a[3]:"";
    try {
      switch(cmd) {
        case "pfx2snk": return PfxToSnk(i,o,pw);
        case "pem2snk": return PemToSnk(i,o,pw);
        case "snk2pem": return SnkToPem(i,o);
        default: Console.Error.WriteLine("unknown command"); return 2;
      }
    } catch (CryptographicException e) { Console.Error.WriteLine(e.Message); return 1; }
      catch (Exception e) { Console.Error.WriteLine(e.ToString()); return 1; }
  }

  static int PfxToSnk(string pfx,string o,string pw) {
    X509Certificate2 cert;
    try { cert=new X509Certificate2(File.ReadAllBytes(pfx),pw, X509KeyStorageFlags.Exportable); }
    catch(Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    using var rsa=cert.GetRSAPrivateKey();
    if (rsa==null) { Console.Error.WriteLine("certificate does not contain an RSA private key"); return 3; }
    try {
      var prm=rsa.ExportParameters(true);
      using var csp=new RSACryptoServiceProvider();
      csp.ImportParameters(prm);
      File.WriteAllBytes(o,csp.ExportCspBlob(true));
      return 0;
    } catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
  }

  static int PemToSnk(string pemPath,string o,string pw) {
    var txt=File.ReadAllText(pemPath);
    using var rsa=RSA.Create();
    try {
      if (!string.IsNullOrEmpty(pw)) rsa.ImportFromEncryptedPem(txt.AsSpan(), pw);
      else rsa.ImportFromPem(txt.AsSpan());
    } catch {
      try {
        var b64=ExtractBase64(txt);
        var der=Convert.FromBase64String(b64);
        try { rsa.ImportPkcs8PrivateKey(der, out _); }
        catch { rsa.ImportRSAPrivateKey(der, out _); }
      } catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }
    try {
      var prm=rsa.ExportParameters(true);
      using var csp=new RSACryptoServiceProvider();
      csp.ImportParameters(prm);
      File.WriteAllBytes(o,csp.ExportCspBlob(true));
      return 0;
    } catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
  }

  static int SnkToPem(string snk,string o) {
    try {
      var blob=File.ReadAllBytes(snk);
      using var csp=new RSACryptoServiceProvider();
      csp.ImportCspBlob(blob);
      using var rsa=RSA.Create();
      rsa.ImportParameters(csp.ExportParameters(true));
      var der=rsa.ExportPkcs8PrivateKey();
      File.WriteAllText(o, ToPem("PRIVATE KEY", der));
      return 0;
    } catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
  }

  static string ExtractBase64(string pem) {
    var lines=pem.Split(new[]{'\r','\n'}, StringSplitOptions.RemoveEmptyEntries);
    var sb=new StringBuilder();
    foreach(var line in lines) if (!line.StartsWith("-----")) sb.Append(line.Trim());
    return sb.ToString();
  }

  static string ToPem(string label, byte[] der) {
    var b=Convert.ToBase64String(der);
    var nl=Environment.NewLine;
    var sb=new StringBuilder();
    sb.Append("-----BEGIN ").Append(label).Append("-----").Append(nl);
    for(int i=0;i<b.Length;i+=64) sb.Append(b, i, Math.Min(64, b.Length - i)).Append(nl);
    sb.Append("-----END ").Append(label).Append("-----").Append(nl);
    return sb.ToString();
  }
}
CS
  dotnet publish "$dir" -c Release -o "$dir/out" >/dev/null 2>"$ERR" || return 1
  SNK_TOOL="$dir/out/snktool.dll"
  [ -s "$SNK_TOOL" ]
}

rsa_supports_msblob() { openssl rsa -help 2>&1 | tr '[:lower:]' '[:upper:]' | grep -q MSBLOB; }

detect_type() {
  local f="$1"
  if is_pem "$f"; then
    pem_has_key "$f" && { printf 'pem\n'; return 0; }
    pem_has_cert "$f" && { printf 'cer\n'; return 0; }
  fi
  if openssl_pkcs12_probe "$f" "$PASS"; then printf 'pfx\n'; return 0; fi
  if is_der_cert "$f"; then printf 'cer\n'; return 0; fi
  if is_der_key "$f"; then printf 'derkey\n'; return 0; fi
  if is_snk "$f"; then printf 'snk\n'; return 0; fi
  printf 'unknown\n'
}


prepare_input() {
  local spec="$1" out="$2"
  if [ "$spec" = "-" ]; then
    cat >"$out"
    return 0
  fi
  if [ -e "$spec" ]; then
    cp "$spec" "$out"
    return 0
  fi
  b64_decode_str "$spec" "$out" && return 0
  printf '%s' "$spec" >"$out"
  return 0
}

src_raw="$tmp/src.raw"
prepare_input "$IN_SPEC" "$src_raw"

src="$src_raw"
t="$(detect_type "$src")"
if [ "$t" = "unknown" ]; then
  dec="$tmp/src.decoded"
  if b64_decode_file "$src" "$dec"; then
    t="$(detect_type "$dec")"
    [ "$t" != "unknown" ] && src="$dec"
  fi
fi
[ "$t" != "unknown" ] || { : >"$ERR"; die "unsupported or unrecognized input"; }

if [ "$t" = "derkey" ]; then
  pem="$tmp/src.pem"
  derkey_to_pem "$src" "$pem" || die "unsupported or unrecognized input"
  src="$pem"
  t="pem"
fi

ensure_signable() {
  local typ="$1" f="$2"
  case "$typ" in
    pem)
      pem_has_key "$f" || die "PEM missing private key"
      return 0
    ;;
    pfx)
      : >"$ERR"
      local opt; opt="$(pkcs12_legacy_opt)"
      if [ -n "$PASS" ]; then
        openssl pkcs12 $opt -in "$f" -passin pass:"$PASS" -nocerts -nodes -out "$tmp/test.key" >/dev/null 2>"$ERR" || die "PFX private key not accessible (password?)"
      else
        openssl pkcs12 $opt -in "$f" -passin pass: -nocerts -nodes -out "$tmp/test.key" >/dev/null 2>"$ERR" || die "PFX requires password"
      fi
      rm -f "$tmp/test.key"
      return 0
    ;;
    snk)
      : >"$ERR"
      if rsa_supports_msblob; then
        openssl rsa -inform MSBLOB -in "$f" -noout -modulus >/dev/null 2>"$ERR" || die "invalid SNK"
      else
        ensure_dotnet_snk_tool || die "invalid SNK"
        local t="$tmp/.snkprobe.pem"
        dotnet "$SNK_TOOL" snk2pem "$f" "$t" >/dev/null 2>"$ERR" || die "invalid SNK"
        [ -s "$t" ] || die "invalid SNK"
      fi
      return 0
    ;;
    *) die "unsupported type: $typ" ;;
  esac
}

ensure_signable "$t" "$src"

algo_of() {
  local typ="$1" f="$2" a="unknown"
  case "$typ" in
    pfx)
      local opt; opt="$(pkcs12_legacy_opt || true)"
      if [ -n "$PASS" ]; then
        a="$(openssl pkcs12 $opt -in "$f" -passin pass:"$PASS" -clcerts -nokeys 2>/dev/null | openssl x509 -noout -text 2>/dev/null | awk -F': *' '/Public Key Algorithm/ {print tolower($2); exit}' || true)"
      else
        a="$(openssl pkcs12 $opt -in "$f" -passin pass: -clcerts -nokeys 2>/dev/null | openssl x509 -noout -text 2>/dev/null | awk -F': *' '/Public Key Algorithm/ {print tolower($2); exit}' || true)"
      fi
    ;;
    pem)
      openssl rsa -in "$f" -check -noout >/dev/null 2>&1 && a="rsa" || true
      [ "$a" = "rsa" ] || { openssl ec -in "$f" -text -noout >/dev/null 2>&1 && a="ec" || true; }
      if [ "$a" = "unknown" ] && pem_has_cert "$f"; then
        a="$(openssl x509 -in "$f" -noout -text 2>/dev/null | awk -F': *' '/Public Key Algorithm/ {print tolower($2); exit}' || true)"
      fi
    ;;
    cer)
      if is_pem "$f"; then
        a="$(openssl x509 -in "$f" -noout -text 2>/dev/null | awk -F': *' '/Public Key Algorithm/ {print tolower($2); exit}' || true)"
      else
        a="$(openssl x509 -inform DER -in "$f" -noout -text 2>/dev/null | awk -F': *' '/Public Key Algorithm/ {print tolower($2); exit}' || true)"
      fi
    ;;
    snk) a="rsa" ;;
  esac
  case "$a" in *rsa*) printf 'rsa\n';; *ec*|*ecdsa*) printf 'ec\n';; *) printf 'unknown\n';; esac
}



algo="$(algo_of "$t" "$src")"
out_tmp="$tmp/out.bin"

cert_to_pem() {
  local f="$1" out="$2"
  : >"$ERR"
  if is_pem "$f"; then
    cp "$f" "$out"
  else
    openssl x509 -inform DER -in "$f" -out "$out" >/dev/null 2>"$ERR" || return 1
  fi
}

pfx_to_pem() {
  local f="$1" out="$2" opt
  : >"$ERR"
  opt="$(pkcs12_legacy_opt)"
  if [ -n "$PASS" ]; then
    openssl pkcs12 $opt -in "$f" -passin pass:"$PASS" -nodes -out "$out" >/dev/null 2>"$ERR" || return 1
  else
    openssl pkcs12 $opt -in "$f" -passin pass: -nodes -out "$out" >/dev/null 2>"$ERR" || return 1
  fi
}

pfx_to_snk() {
  local f="$1" out="$2" opt
  [ "$algo" = "rsa" ] || die "SNK requires RSA"
  : >"$ERR"
  opt="$(pkcs12_legacy_opt)"
  if rsa_supports_msblob; then
    local key="$tmp/key.pem"
    if [ -n "$PASS" ]; then
      openssl pkcs12 $opt -in "$f" -passin pass:"$PASS" -nocerts -nodes -out "$key" >/dev/null 2>"$ERR" || return 1
    else
      openssl pkcs12 $opt -in "$f" -passin pass: -nocerts -nodes -out "$key" >/dev/null 2>"$ERR" || return 1
    fi
    openssl rsa -in "$key" -outform MSBLOB -out "$out" >/dev/null 2>"$ERR" || true
    [ -s "$out" ] && return 0
  fi
  ensure_dotnet_snk_tool || return 1
  if [ -n "$PASS" ]; then
    if ! dotnet "$SNK_TOOL" pfx2snk "$f" "$out" "$PASS" >/dev/null 2>"$ERR"; then rc=$?; [ -s "$ERR" ] || printf 'snktool pfx2snk failed with exit %d\n' "$rc" >"$ERR"; return 1; fi
  else
    if ! dotnet "$SNK_TOOL" pfx2snk "$f" "$out" >/dev/null 2>"$ERR"; then rc=$?; [ -s "$ERR" ] || printf 'snktool pfx2snk failed with exit %d\n' "$rc" >"$ERR"; return 1; fi
  fi
  return 0
}

pem_to_snk() {
  local f="$1" out="$2"
  [ "$algo" = "rsa" ] || die "SNK requires RSA"
  : >"$ERR"
  if rsa_supports_msblob; then
    if [ -n "$PASS" ]; then
      openssl rsa -in "$f" -passin pass:"$PASS" -outform MSBLOB -out "$out" >/dev/null 2>"$ERR" || true
    else
      openssl rsa -in "$f" -outform MSBLOB -out "$out" >/dev/null 2>"$ERR" || true
    fi
    [ -s "$out" ] && return 0
  fi
  ensure_dotnet_snk_tool || return 1
  if [ -n "$PASS" ]; then
    if ! dotnet "$SNK_TOOL" pem2snk "$f" "$out" "$PASS" >/dev/null 2>"$ERR"; then rc=$?; [ -s "$ERR" ] || printf 'snktool pem2snk failed with exit %d\n' "$rc" >"$ERR"; return 1; fi
  else
    if ! dotnet "$SNK_TOOL" pem2snk "$f" "$out" >/dev/null 2>"$ERR"; then rc=$?; [ -s "$ERR" ] || printf 'snktool pem2snk failed with exit %d\n' "$rc" >"$ERR"; return 1; fi
  fi
  return 0
}

snk_to_pem() {
  local f="$1" out="$2"
  : >"$ERR"
  if rsa_supports_msblob; then
    openssl rsa -inform MSBLOB -in "$f" -out "$out" >/dev/null 2>"$ERR" && return 0
  fi
  ensure_dotnet_snk_tool || return 1
  if ! dotnet "$SNK_TOOL" snk2pem "$f" "$out" >/dev/null 2>"$ERR"; then rc=$?; [ -s "$ERR" ] || printf 'snktool snk2pem failed with exit %d\n' "$rc" >"$ERR"; return 1; fi
  return 0
}

pem_to_pfx() {
  local f="$1" out="$2"
  : >"$ERR"
  if [ -n "$PASS" ]; then
    openssl pkcs12 -export -inkey "$f" -in "$f" -passin pass:"$PASS" -passout pass:"$PASS" -out "$out" >/dev/null 2>"$ERR" || return 1
  else
    openssl pkcs12 -export -inkey "$f" -in "$f" -passout pass:"$PASS" -out "$out" >/dev/null 2>"$ERR" || return 1
  fi
}

derkey_to_pem() {
  local f="$1" out="$2"
  : >"$ERR"
  openssl pkcs8 -inform DER -in "$f" -nocrypt -out "$out" >/dev/null 2>"$ERR" && return 0
  openssl rsa -inform DER -in "$f" -out "$out" >/dev/null 2>"$ERR" && return 0
  return 1
}

case "$FMT" in
  pem)
    case "$t" in
      pem) cp "$src" "$out_tmp" ;;
      pfx) pfx_to_pem "$src" "$out_tmp" || die "PFX->PEM failed" ;;
      snk) snk_to_pem "$src" "$out_tmp" || die "SNK->PEM failed" ;;
      cer) cert_to_pem "$src" "$out_tmp" || die "CER->PEM failed" ;;
    esac
  ;;
  pfx)
    case "$t" in
      pfx)
        if [ -n "${PASS-}" ]; then
          tmp_pem="$tmp/repack.pem"
          pfx_to_pem "$src" "$tmp_pem" || die "PFX read failed"
          pem_to_pfx "$tmp_pem" "$out_tmp" || die "PFX repack failed"
        else
          cp "$src" "$out_tmp"
        fi
      ;;
      pem)
        pem_has_key "$src" || die "PEM missing private key"
        pem_to_pfx "$src" "$out_tmp" || die "PEM->PFX failed"
      ;;
      snk)
        die "cannot build PFX from SNK without a certificate"
      ;;
      cer)
        die "cannot build PFX from certificate without a private key"
      ;;
    esac
  ;;
  snk)
    [ "$algo" = "rsa" ] || die "SNK requires RSA"
    case "$t" in
      snk) cp "$src" "$out_tmp" ;;
      pfx) pfx_to_snk "$src" "$out_tmp" || die "PFX->SNK failed" ;;
      pem) pem_to_snk "$src" "$out_tmp" || die "PEM->SNK failed" ;;
      cer) die "cannot build SNK from certificate without a private key" ;;
    esac
  ;;
esac

[ -s "$out_tmp" ] || die "empty output"

if [ "$B64_OUT" -eq 1 ]; then
  b64_encode_file "$out_tmp" "$OUT_PATH" || die "base64 encode failed"
else
  cp "$out_tmp" "$OUT_PATH" || die "write failed"
fi