#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[vless]"
STATE_DIR="$HOME/.local/state/shell-scripts"

SERVER_IP="${SERVER_IP:-}"
VLESS_NAME="${VLESS_NAME:-}"
SERVER_PORT="${SERVER_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
VLESS_PORT="${VLESS_PORT:-443}"
REALITY_TARGET="${REALITY_TARGET:-dl.google.com}"
XRAY_VERSION="${XRAY_VERSION:-}"
REPLACE="${REPLACE:-0}"
DISK_HYGIENE="${DISK_HYGIENE:-1}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=20)

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

parse_args() {
  local positional=() arg
  for arg in "$@"; do
    case "$arg" in
      -*) die "Unknown option: $arg" ;;
      *) positional+=("$arg") ;;
    esac
  done
  [ -n "$SERVER_IP" ] || SERVER_IP="${positional[0]:-}"
  [ -n "$VLESS_NAME" ] || VLESS_NAME="${positional[1]:-vless}"
}

ensure_requirements() {
  need_cmd ssh
  need_cmd mktemp
  need_cmd grep

  if [ -z "$SERVER_IP" ]; then
    [ -r /dev/tty ] || die "Set SERVER_IP or pass the server address as the first argument"
    printf 'Server IP: ' > /dev/tty
    IFS= read -r SERVER_IP < /dev/tty
  fi
  [ -n "$SERVER_IP" ] || die "Server IP is required"
  [[ "$SERVER_IP" =~ ^[A-Za-z0-9.:-]+$ ]] || die "Invalid server address: $SERVER_IP"
  [[ "$VLESS_PORT" =~ ^[0-9]+$ ]] && (( VLESS_PORT >= 1 && VLESS_PORT <= 65535 )) || die "Invalid VLESS_PORT: $VLESS_PORT"
  [[ "$VLESS_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "VLESS_NAME may only contain letters, digits, dot, dash and underscore"
  [[ "$REALITY_TARGET" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid REALITY_TARGET: $REALITY_TARGET"
  [[ -z "$XRAY_VERSION" || "$XRAY_VERSION" =~ ^v?[0-9][0-9.]*$ ]] || die "Invalid XRAY_VERSION: $XRAY_VERSION"
  [[ -z "$SSH_KEY" || -f "$SSH_KEY" ]] || die "SSH_KEY not found: $SSH_KEY"
}

# Runs on the server as root. Reads its settings from the environment; prints VLESS_* lines at the end.
remote_script() {
  cat <<'REMOTE'
set -euo pipefail

rlog() { printf '[vless:server] %s\n' "$*"; }
rdie() { printf '[vless:server] ERROR: %s\n' "$*" >&2; exit 1; }

CONFIG_DIR="/usr/local/etc/xray"
CONFIG="$CONFIG_DIR/config.json"
XRAY=/usr/local/bin/xray

[ "$(id -u)" -eq 0 ] || rdie "must run as root"
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  ubuntu:*|debian:*|*:debian*) ;;
  *) rdie "only Debian/Ubuntu servers are supported (found ${ID:-unknown})" ;;
esac

avail_mb=$(df --output=avail -m / | tail -1 | tr -d ' ')
[ "$avail_mb" -ge 300 ] || rdie "only ${avail_mb} MB free on /; free some space first"

if [ -f "$CONFIG" ] && grep -q '"reality"' "$CONFIG" && [ "$REPLACE" != "1" ]; then
  rdie "$CONFIG already holds a Reality setup; run again with REPLACE=1 to replace it (the old file is kept as a backup)"
fi

export DEBIAN_FRONTEND=noninteractive
rlog "installing packages"
apt-get update -qq
apt-get install -y -qq curl unzip ca-certificates openssl >/dev/null

rlog "installing Xray${XRAY_VERSION:+ $XRAY_VERSION}"
installer="$(mktemp)"
curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer"
if [ -n "$XRAY_VERSION" ]; then
  bash "$installer" install --version "v${XRAY_VERSION#v}" >/dev/null
else
  bash "$installer" install >/dev/null
fi
rm -f "$installer"
[ -x "$XRAY" ] || rdie "Xray was not installed"

rlog "generating the client id and Reality keys"
uuid="$("$XRAY" uuid)"
keys="$("$XRAY" x25519)"
private_key="$(printf '%s\n' "$keys" | sed -n 's/^[Pp]rivate[ ]*[Kk]ey:[ ]*//p' | head -1)"
public_key="$(printf '%s\n' "$keys" | sed -n 's/^\(Public[ ]*[Kk]ey\|Password[^:]*\):[ ]*//p' | head -1)"
[ -n "$private_key" ] && [ -n "$public_key" ] || rdie "could not read the keys from 'xray x25519'"
short_id="$(openssl rand -hex 8)"

if [ -f "$CONFIG" ]; then
  backup="$CONFIG.bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$CONFIG" "$backup"
  rlog "old config kept as $backup"
  # Keep the three newest backups.
  ls -1t "$CONFIG".bak-* 2>/dev/null | tail -n +4 | xargs -r rm -f
fi

new_config="$CONFIG_DIR/config.json.new.json"
cat >"$new_config" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$uuid", "email": "$VLESS_NAME", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_TARGET:443",
          "xver": 0,
          "serverNames": ["$REALITY_TARGET"],
          "privateKey": "$private_key",
          "shortIds": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
JSON
chown root:nogroup "$new_config"
chmod 640 "$new_config"
"$XRAY" run -test -format json -config "$new_config" >/tmp/xray-test.out 2>&1 || { tail -5 /tmp/xray-test.out >&2; rm -f "$new_config"; rdie "Xray rejected the generated config; nothing was changed"; }
mv "$new_config" "$CONFIG"

if [ "$DISK_HYGIENE" = "1" ]; then
  rlog "keeping the disk from filling up (journal cap, no apt caches, weekly tidy)"
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=30M\nRuntimeMaxUse=20M\n' >/etc/systemd/journald.conf.d/size.conf
  systemctl restart systemd-journald || true
  printf 'Acquire::Languages "none";\n' >/etc/apt/apt.conf.d/99-no-translations
  printf 'Dir::Cache::pkgcache "";\nDir::Cache::srcpkgcache "";\n' >/etc/apt/apt.conf.d/98-no-pkgcache
  rm -f /var/lib/apt/lists/*Translation* /var/cache/apt/*.bin
  printf '#!/bin/sh\napt-get clean\njournalctl --vacuum-size=30M >/dev/null 2>&1\n' >/etc/cron.weekly/disk-tidy
  chmod +x /etc/cron.weekly/disk-tidy
  if command -v snap >/dev/null 2>&1; then snap set system refresh.retain=2 || true; fi
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
  rlog "opening $VLESS_PORT/tcp in ufw"
  ufw allow "$VLESS_PORT/tcp" >/dev/null
fi

systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 3
port="$(grep -o '"port": *[0-9]*' "$CONFIG" | head -1 | grep -o '[0-9]*$')"
if ! systemctl is-active --quiet xray || ! ss -tln | grep -q ":$port "; then
  journalctl -u xray --no-pager -n 15 >&2 || true
  if [ -n "${backup:-}" ]; then
    cp -p "$backup" "$CONFIG"
    systemctl restart xray || true
    rdie "Xray did not start on the new config; the old one was restored"
  fi
  rdie "Xray did not start on port $port"
fi
rlog "Xray is running on port $port; memory: $(ps -o rss= -C xray | awk '{printf "%d MB", $1/1024}'), $(free -m | awk '/Mem:/{print $7}') MB available"

printf 'VLESS_UUID=%s\nVLESS_PUBLIC_KEY=%s\nVLESS_SHORT_ID=%s\n' "$uuid" "$public_key" "$short_id"
REMOTE
}

remote_env() {
  printf 'VLESS_PORT=%q VLESS_NAME=%q REALITY_TARGET=%q XRAY_VERSION=%q REPLACE=%q DISK_HYGIENE=%q' \
    "$VLESS_PORT" "$VLESS_NAME" "$REALITY_TARGET" "$XRAY_VERSION" "$REPLACE" "$DISK_HYGIENE"
}

run_remote() {
  local output="$1" key_opts=()
  [ -z "$SSH_KEY" ] || key_opts=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
  log "Connecting to root@$SERVER_IP (type the root password when asked)"
  remote_script | ssh "${SSH_OPTS[@]}" ${key_opts[@]+"${key_opts[@]}"} -p "$SERVER_PORT" \
    -o PreferredAuthentications=publickey,keyboard-interactive,password \
    "root@$SERVER_IP" "$(remote_env) bash -s" | tee "$output"
}

print_result() {
  local output="$1" uuid public_key short_id host link state_file

  uuid="$(sed -n 's/^VLESS_UUID=//p' "$output" | tail -1)"
  public_key="$(sed -n 's/^VLESS_PUBLIC_KEY=//p' "$output" | tail -1)"
  short_id="$(sed -n 's/^VLESS_SHORT_ID=//p' "$output" | tail -1)"
  [ -n "$uuid" ] && [ -n "$public_key" ] && [ -n "$short_id" ] || die "The server did not return the connection details"

  host="$SERVER_IP"
  [[ "$host" == *:* ]] && host="[$host]"
  link="vless://${uuid}@${host}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${VLESS_NAME}"

  mkdir -p "$STATE_DIR"
  state_file="$STATE_DIR/vless-${SERVER_IP//[^A-Za-z0-9._-]/_}.env"
  umask 077
  printf 'SERVER_IP=%s\nVLESS_PORT=%s\nVLESS_LINK=%s\n' "$SERVER_IP" "$VLESS_PORT" "$link" >"$state_file"

  printf '\nDone.\n'
  printf 'Import this link into your VLESS client (v2rayNG, Hiddify, Happ, ...):\n\n%s\n\n' "$link"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$link"
  fi
  log "Saved to $state_file"
}

main() {
  parse_args "$@"
  ensure_requirements
  local output
  output="$(mktemp)"
  trap 'rm -f "$output"' EXIT
  run_remote "$output"
  print_result "$output"
}

main "$@"
