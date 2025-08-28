#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

ACTION="${1:-}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd -P)"
LOCK_DIR="$BASE_DIR/run"
PID_DIR="$BASE_DIR/run"
SQUID_PID="$PID_DIR/squid.pid"
MONITOR_PID="$PID_DIR/monitor.pid"
LOCK_FILE="$LOCK_DIR/lock"
SQUID_PKG="squid-openssl"
SQUID_COMMON_PKG="squid-common"
SQUID_USER="proxy"
SQUID_GROUP="proxy"
HTTP_PORT="3128"
HTTPS_PORT="3129"
HOSTNAME_TAG="squid-mitm"
CA_DIR="$BASE_DIR/mitm_ca"
CA_KEY="$CA_DIR/ca.key"
CA_CRT="$CA_DIR/ca.crt"
CA_PEM="$CA_DIR/ca.pem"
CA_DAYS="3650"
CA_SUBJ="/CN=$HOSTNAME_TAG/O=$HOSTNAME_TAG/L=Local/C=NA"
SSL_DB_DIR="$BASE_DIR/ssl_db"
CACHE_IF_STANDALONE_BIN="$BASE_DIR/cache"
SQUID_BIN="$BASE_DIR/squid"
SQUID_CONF="$BASE_DIR/squid.conf"
SQUID_CONF_BAK="$BASE_DIR/squid.conf.bak.mitm"
SQUID_LOG="$BASE_DIR/cache.log"
CACHE_SIZE_MB="10240"
MEM_CACHE_MB="128"
FILE_MIMES_REGEX="application/(octet-stream|zip|x-zip-compressed|x-gzip|x-xz|x-bzip2|x-7z-compressed|x-tar|x-debian-package|x-rpm|java-archive|gzip|zstd|x-iso9660-image|vnd\\.ms-cab-compressed|x-msdownload)|image/.*|video/.*|audio/.*|application/pdf"
REFRESH_LONG_MIN="525600"
IPTABLES_CHAIN="SQUID_LOCAL"

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { echo "sudo required"; exit 1; }
    exec sudo "$0" "$ACTION"
  fi
}

ensure_dirs() {
  mkdir -p "$LOCK_DIR" "$PID_DIR" "$CA_DIR" "$CACHE_IF_STANDALONE_BIN"
  chmod 755 "$BASE_DIR"
}

prepare_ssl_db_dir() {
  local helper="$1"
  rm -rf "$SSL_DB_DIR"
  "$helper" -c -s "$SSL_DB_DIR" -M 20MB
  chown -R "$SQUID_USER:$SQUID_GROUP" "$SSL_DB_DIR"
}

cache_dir_pick() {
  echo "$CACHE_IF_STANDALONE_BIN"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates iptables libecap3
  if [ ! -x "$SQUID_BIN" ] || ! "$SQUID_BIN" -v 2>&1 | grep -q -- '--enable-ssl-crtd'; then
    rm -f "$BASE_DIR"/${SQUID_PKG}_*.deb "$BASE_DIR"/${SQUID_COMMON_PKG}_*.deb
    apt-get download "$SQUID_PKG" "$SQUID_COMMON_PKG"
    deb="$(find . -maxdepth 1 -name "${SQUID_PKG}_*.deb" | head -n1)"
    debc="$(find . -maxdepth 1 -name "${SQUID_COMMON_PKG}_*.deb" | head -n1)"
    rm -rf "$BASE_DIR/squid-extracted" "$BASE_DIR/squid-common-extracted"
    dpkg-deb -x "$deb" "$BASE_DIR/squid-extracted"
    dpkg-deb -x "$debc" "$BASE_DIR/squid-common-extracted"
    install -m 0755 "$BASE_DIR/squid-extracted/usr/sbin/squid" "$SQUID_BIN"
    if [ -x "$BASE_DIR/squid-extracted/usr/lib/squid/security_file_certgen" ]; then
      install -m 0755 "$BASE_DIR/squid-extracted/usr/lib/squid/security_file_certgen" "$BASE_DIR/"
    fi
    if [ -x "$BASE_DIR/squid-extracted/usr/lib/squid/ssl_crtd" ]; then
      install -m 0755 "$BASE_DIR/squid-extracted/usr/lib/squid/ssl_crtd" "$BASE_DIR/"
    fi
    if [ -x "$BASE_DIR/squid-extracted/usr/lib/squid/unlinkd" ]; then
      install -m 0755 "$BASE_DIR/squid-extracted/usr/lib/squid/unlinkd" "$BASE_DIR/"
    fi
    if [ -x "$BASE_DIR/squid-extracted/usr/lib/squid/log_file_daemon" ]; then
      install -m 0755 "$BASE_DIR/squid-extracted/usr/lib/squid/log_file_daemon" "$BASE_DIR/"
    fi
    if [ -f "$BASE_DIR/squid-common-extracted/usr/share/squid/mime.conf" ]; then
      install -m 0644 "$BASE_DIR/squid-common-extracted/usr/share/squid/mime.conf" "$BASE_DIR/mime.conf"
    fi
    if [ -d "$BASE_DIR/squid-common-extracted/usr/share/squid/icons" ]; then
      rm -rf "$BASE_DIR/icons"
      cp -r "$BASE_DIR/squid-common-extracted/usr/share/squid/icons" "$BASE_DIR/icons"
    fi
    rm -rf "$BASE_DIR/squid-extracted" "$BASE_DIR/squid-common-extracted" "$deb" "$debc"
  fi
}

stop_system_squid() {
  pkill -x squid >/dev/null 2>&1 || true
  rm -f /run/squid.pid
}

detect_ssl_helper() {
  if [ -x "$BASE_DIR/security_file_certgen" ]; then
    echo "$BASE_DIR/security_file_certgen"
  elif [ -x "$BASE_DIR/ssl_crtd" ]; then
    echo "$BASE_DIR/ssl_crtd"
  else
    echo ""
  fi
}

gen_ca() {
  if [ ! -f "$CA_PEM" ]; then
    openssl req -new -newkey rsa:4096 -sha256 -days "$CA_DAYS" -nodes -x509 -keyout "$CA_KEY" -out "$CA_CRT" -subj "$CA_SUBJ"
    cat "$CA_KEY" "$CA_CRT" > "$CA_PEM"
    chown -R "$SQUID_USER:$SQUID_GROUP" "$CA_DIR"
    chmod 0400 "$CA_KEY"
  fi
}

trust_ca() {
  install -m 0644 "$CA_CRT" "/usr/local/share/ca-certificates/$HOSTNAME_TAG.crt"
  update-ca-certificates >/dev/null
}

untrust_ca() {
  rm -f "/usr/local/share/ca-certificates/$HOSTNAME_TAG.crt"
  update-ca-certificates >/dev/null
}

write_squid_conf() {
  local helper="$1"
  local cache_dir="$2"
  [ -f "$SQUID_CONF" ] && [ ! -f "$SQUID_CONF_BAK" ] && cp -f "$SQUID_CONF" "$SQUID_CONF_BAK"
  install -d -o "$SQUID_USER" -g "$SQUID_GROUP" "$cache_dir"
  install -d -o "$SQUID_USER" -g "$SQUID_GROUP" "$(dirname "$SQUID_LOG")"
  cat >"$SQUID_CONF" <<EOF
visible_hostname $HOSTNAME_TAG
pid_filename $SQUID_PID
acl localnet src all
acl step1 at_step SslBump1
http_port $HTTP_PORT intercept
https_port $HTTPS_PORT intercept ssl-bump generate-host-certificates=on dynamic_cert_mem_cache_size=4MB cert=$CA_PEM
sslcrtd_program $helper -s $SSL_DB_DIR -M 20MB
sslcrtd_children 5 startup=1 idle=1
unlinkd_program $BASE_DIR/unlinkd
logfile_daemon $BASE_DIR/log_file_daemon
mime_table $BASE_DIR/mime.conf
icon_directory $BASE_DIR/icons
ssl_bump peek step1
ssl_bump bump all
http_access allow localnet
cache_dir ufs $cache_dir ${CACHE_SIZE_MB} 16 256
cache_mem ${MEM_CACHE_MB} MB
maximum_object_size 102400 MB
maximum_object_size_in_memory 8 MB
acl file_mime rep_mime_type -i $FILE_MIMES_REGEX
cache deny !file_mime
refresh_pattern -i \.(deb|rpm|zip|gz|xz|zst|7z|tar|tgz|bz2|iso|img|whl|jar|pdf|png|jpe?g|gif|webp|mp4|avi|mkv|mp3|flac)$ 0 100% ${REFRESH_LONG_MIN} ignore-reload override-expire override-lastmod ignore-no-cache ignore-no-store ignore-private
refresh_pattern . 0 20% ${REFRESH_LONG_MIN} ignore-reload override-expire override-lastmod ignore-no-cache ignore-no-store ignore-private
tls_outgoing_options cafile=/etc/ssl/certs/ca-certificates.crt
cache_log $SQUID_LOG
EOF
  chown "$SQUID_USER:$SQUID_GROUP" "$SQUID_CONF"
}

iptables_enable() {
  local squid_uid
  if ! iptables -t nat -L >/dev/null 2>&1; then
    return
  fi
  squid_uid="$(id -u "$SQUID_USER")"
  iptables -t nat -N "$IPTABLES_CHAIN" 2>/dev/null || true
  iptables -t nat -C OUTPUT -j "$IPTABLES_CHAIN" 2>/dev/null || iptables -t nat -A OUTPUT -j "$IPTABLES_CHAIN"
  iptables -t nat -C "$IPTABLES_CHAIN" -m owner --uid-owner "$squid_uid" -j RETURN 2>/dev/null || iptables -t nat -A "$IPTABLES_CHAIN" -m owner --uid-owner "$squid_uid" -j RETURN
  iptables -t nat -C "$IPTABLES_CHAIN" -d 127.0.0.0/8 -j RETURN 2>/dev/null || iptables -t nat -A "$IPTABLES_CHAIN" -d 127.0.0.0/8 -j RETURN
  iptables -t nat -C "$IPTABLES_CHAIN" -p tcp --dport 80 -j REDIRECT --to-ports "$HTTP_PORT" 2>/dev/null || iptables -t nat -A "$IPTABLES_CHAIN" -p tcp --dport 80 -j REDIRECT --to-ports "$HTTP_PORT"
  iptables -t nat -C "$IPTABLES_CHAIN" -p tcp --dport 443 -j REDIRECT --to-ports "$HTTPS_PORT" 2>/dev/null || iptables -t nat -A "$IPTABLES_CHAIN" -p tcp --dport 443 -j REDIRECT --to-ports "$HTTPS_PORT"
}

iptables_disable() {
  if ! iptables -t nat -L >/dev/null 2>&1; then
    return
  fi
  if iptables -t nat -S OUTPUT | grep -q "$IPTABLES_CHAIN"; then
    iptables -t nat -D OUTPUT -j "$IPTABLES_CHAIN" || true
  fi
  if iptables -t nat -S | grep -q "^-N $IPTABLES_CHAIN"; then
    while iptables -t nat -S "$IPTABLES_CHAIN" | grep -q "^-A $IPTABLES_CHAIN"; do
      local rule
      rule="$(iptables -t nat -S "$IPTABLES_CHAIN" | grep "^-A $IPTABLES_CHAIN" | head -n1 | sed 's/^-A /-D /')"
      read -r -a parts <<< "$rule"
      iptables -t nat "${parts[@]}" || true
    done
    iptables -t nat -X "$IPTABLES_CHAIN" || true
  fi
}

squid_prepare_cache() {
  "$SQUID_BIN" -f "$SQUID_CONF" -z || true
  rm -f "$SQUID_PID"
}

squid_start() {
  "$SQUID_BIN" -f "$SQUID_CONF"
}

squid_stop() {
  if [ -f "$SQUID_PID" ] && kill -0 "$(cat "$SQUID_PID")" 2>/dev/null; then
    "$SQUID_BIN" -k shutdown || kill "$(cat "$SQUID_PID")" || true
  fi
  rm -f "$SQUID_PID"
}

monitor_start() {
  if [ -f "$MONITOR_PID" ] && kill -0 "$(cat "$MONITOR_PID")" 2>/dev/null; then
    exit 0
  fi
  nohup bash -c "
    while true; do
      if [ ! -f '$SQUID_PID' ] || ! kill -0 \$(cat '$SQUID_PID') 2>/dev/null; then
        iptables_disable
        untrust_ca
        exit 0
      fi
      sleep 2
    done
  " >/dev/null 2>&1 &
  echo $! > "$MONITOR_PID"
}

monitor_stop() {
  if [ -f "$MONITOR_PID" ] && kill -0 "$(cat "$MONITOR_PID")" 2>/dev/null; then
    kill "$(cat "$MONITOR_PID")" || true
    rm -f "$MONITOR_PID"
  fi
}

start() {
  require_root
  ensure_dirs
  if [ -f "$SQUID_PID" ]; then
    if kill -0 "$(cat "$SQUID_PID")" 2>/dev/null; then echo "already running"; exit 1; fi
    rm -f "$SQUID_PID"
  fi
  if [ -f "$LOCK_FILE" ]; then exit 0; fi
  touch "$LOCK_FILE"
  install_packages
  stop_system_squid
  squid_stop
  local helper
  helper="$(detect_ssl_helper)"
  [ -n "$helper" ] || { echo "ssl helper not found"; rm -f "$LOCK_FILE"; exit 1; }
  gen_ca
  trust_ca
  local cache_dir
  cache_dir="$(cache_dir_pick)"
  write_squid_conf "$helper" "$cache_dir"
  prepare_ssl_db_dir "$helper"
  "$SQUID_BIN" -f "$SQUID_CONF" -k parse
  squid_prepare_cache
  squid_start
  t=0
  while true; do
    if [ -f "$SQUID_PID" ] && kill -0 "$(cat "$SQUID_PID")" 2>/dev/null; then break; fi
    if [ "$t" -ge 30 ]; then rm -f "$LOCK_FILE"; echo timeout; exit 1; fi
    sleep 1
    t=$((t+1))
  done
  iptables_enable
  monitor_start
  echo "started"
}

stop() {
  require_root
  monitor_stop
  iptables_disable
  untrust_ca
  squid_stop
  stop_system_squid
  rm -f "$LOCK_FILE"
  echo "stopped"
}

case "$ACTION" in
  start) start ;;
  stop) stop ;;
  restart|'') stop; start ;;
  *) echo "usage: $0 {start|stop|restart}"; exit 1 ;;
esac
