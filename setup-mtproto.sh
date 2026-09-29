#!/usr/bin/env bash
set -euo pipefail

MT_PORTS="${1:-${MT_PORTS:-443,8443}}"
STATS_PORT="${2:-${STATS_PORT:-8888}}"
SERVER_DOMAIN="${3:-${SERVER_DOMAIN:-${DOMAIN:-}}}"
WORKDIR="/opt/mtproxy"
SERVICE_NAME="mtproxy"
OS_ID=""
OS_LIKE=""
PKG_MANAGER=""

if [[ "${EUID}" -ne 0 ]]; then
  printf 'Run this script as root\n' >&2
  exit 1
fi

normalize_ports() {
  local raw="$1"
  local port normalized=""

  raw="${raw// /}"
  raw="${raw//;/,}"
  IFS=',' read -r -a ports <<<"${raw}"
  for port in "${ports[@]}"; do
    if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      printf 'Invalid port: %s\n' "${port}" >&2
      exit 1
    fi
    if [[ -z "${normalized}" ]]; then
      normalized="${port}"
    else
      normalized="${normalized},${port}"
    fi
  done

  if [[ -z "${normalized}" ]]; then
    printf 'At least one MTProto port is required\n' >&2
    exit 1
  fi
  printf '%s\n' "${normalized}"
}

first_port() {
  local ports="$1"
  printf '%s\n' "${ports%%,*}"
}

endpoint_host() {
  if [[ -n "${SERVER_DOMAIN}" ]]; then
    printf '%s\n' "${SERVER_DOMAIN}"
    return
  fi
  curl -4 -s ifconfig.me || true
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    printf 'Unsupported OS: missing /etc/os-release\n' >&2
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"

  case "${OS_ID}:${OS_LIKE}" in
    ubuntu:*|debian:*|*:debian*)
      PKG_MANAGER="apt"
      ;;
    almalinux:*|rocky:*|centos:*|rhel:*|*:rhel*|*:fedora*)
      PKG_MANAGER="dnf"
      ;;
    *)
      printf 'Unsupported OS: %s\n' "${OS_ID:-unknown}" >&2
      exit 1
      ;;
  esac
}

install_packages() {
  case "${PKG_MANAGER}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y git curl build-essential libssl-dev zlib1g-dev ufw ca-certificates openssl
      ;;
    dnf)
      dnf install -y git curl gcc make openssl-devel zlib-devel firewalld ca-certificates openssl
      ;;
  esac
}

ensure_mtproxy_user() {
  if ! id -u mtproxy >/dev/null 2>&1; then
    useradd --system --home-dir "${WORKDIR}" --no-create-home --user-group --shell /usr/sbin/nologin mtproxy 2>/dev/null \
      || useradd --system --home-dir "${WORKDIR}" --no-create-home --user-group --shell /sbin/nologin mtproxy
  fi
}

prepare_workdir() {
  local tmpdir

  if [[ -d "${WORKDIR}/.git" ]]; then
    git -C "${WORKDIR}" pull --ff-only
    return
  fi

  mkdir -p "${WORKDIR}"

  tmpdir="$(mktemp -d)"
  git clone https://github.com/TelegramMessenger/MTProxy.git "${tmpdir}/MTProxy"
  cp -a "${tmpdir}/MTProxy/." "${WORKDIR}/"
  rm -rf "${tmpdir}"
}

open_firewall_ports() {
  local port
  IFS=',' read -r -a ports <<<"${MT_PORTS}"

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
    for port in "${ports[@]}"; do
      ufw allow "${port}/tcp"
    done
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    for port in "${ports[@]}"; do
      firewall-cmd --permanent --add-port="${port}/tcp"
    done
    firewall-cmd --reload
  fi
}

MT_PORTS="$(normalize_ports "${MT_PORTS}")"
MT_PRIMARY_PORT="$(first_port "${MT_PORTS}")"
if [[ ! "${STATS_PORT}" =~ ^[0-9]+$ ]] || (( STATS_PORT < 1 || STATS_PORT > 65535 )); then
  printf 'Invalid stats port: %s\n' "${STATS_PORT}" >&2
  exit 1
fi

detect_os
install_packages

ensure_mtproxy_user

prepare_workdir

make -C "${WORKDIR}"

SECRET="$(openssl rand -hex 16)"

curl -fsSL https://core.telegram.org/getProxySecret -o "${WORKDIR}/proxy-secret"
curl -fsSL https://core.telegram.org/getProxyConfig -o "${WORKDIR}/proxy-multi.conf"

chown -R mtproxy:mtproxy "${WORKDIR}"
chmod 600 "${WORKDIR}/proxy-secret" "${WORKDIR}/proxy-multi.conf"

cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Telegram MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${WORKDIR}
ExecStart=${WORKDIR}/objs/bin/mtproto-proxy -u mtproxy -p ${STATS_PORT} -H ${MT_PORTS} -S ${SECRET} --aes-pwd ${WORKDIR}/proxy-secret ${WORKDIR}/proxy-multi.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

open_firewall_ports

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

SERVER_HOST="$(endpoint_host)"

printf '\nDone.\n'
printf 'MTProto endpoints\n'
IFS=',' read -r -a ports <<<"${MT_PORTS}"
for port in "${ports[@]}"; do
  printf '%s:%s\n' "${SERVER_HOST:-SERVER_IP}" "${port}"
done
printf 'Secret\n'
printf '%s\n' "${SECRET}"
printf 'Telegram link\n'
printf 'https://t.me/proxy?server=%s&port=%s&secret=%s\n' "${SERVER_HOST:-SERVER_IP}" "${MT_PRIMARY_PORT}" "${SECRET}"
