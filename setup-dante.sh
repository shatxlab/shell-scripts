#!/usr/bin/env bash
set -euo pipefail

PROXY_PORT="${1:-${PROXY_PORT:-24861}}"
SERVER_DOMAIN="${2:-${SERVER_DOMAIN:-${DOMAIN:-}}}"

OS_ID=""
OS_LIKE=""
PKG_MANAGER=""
DANTE_SERVICE=""
DANTE_CONFIG=""

if [[ "${EUID}" -ne 0 ]]; then
  printf 'Run this script as root\n' >&2
  exit 1
fi

validate_port() {
  local port="$1"
  if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    printf 'Invalid port: %s\n' "${port}" >&2
    exit 1
  fi
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
      DANTE_SERVICE="danted"
      DANTE_CONFIG="/etc/danted.conf"
      ;;
    almalinux:*|rocky:*|centos:*|rhel:*|*:rhel*|*:fedora*)
      PKG_MANAGER="dnf"
      DANTE_SERVICE="sockd"
      DANTE_CONFIG="/etc/sockd.conf"
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
      if apt-get install -y dante-server ufw curl; then
        :
      else
        # dante-server was dropped from the Debian trixie archive (bug #1067709);
        # fall back to the current deb from the Debian pool.
        apt-get install -y ufw curl
        DEB_ARCH="$(dpkg --print-architecture)"
        DEB_NAME="$(curl -fsSL https://deb.debian.org/debian/pool/main/d/dante/ \
          | grep -oE 'dante-server_[^"]+_'"${DEB_ARCH}"'\.deb' | sort -V | tail -n 1)"
        DEB_FILE="$(mktemp /tmp/dante-server_XXXXXX.deb)"
        curl -fsSL -o "${DEB_FILE}" "https://deb.debian.org/debian/pool/main/d/dante/${DEB_NAME}"
        apt-get install -y "${DEB_FILE}"
        rm -f "${DEB_FILE}"
      fi
      ;;
    dnf)
      dnf install -y epel-release
      dnf install -y dnf-plugins-core || true
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
      dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
      dnf install -y dante-server firewalld curl iproute
      ;;
  esac
}

ensure_sockd_user() {
  if ! id -u sockd >/dev/null 2>&1; then
    useradd --system --no-create-home --user-group --shell /usr/sbin/nologin sockd 2>/dev/null \
      || useradd --system --no-create-home --user-group --shell /sbin/nologin sockd
  fi
}

open_firewall_port() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
    ufw allow "${PROXY_PORT}/tcp"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${PROXY_PORT}/tcp"
    firewall-cmd --reload
  fi
}

validate_port "${PROXY_PORT}"

detect_os
install_packages

ensure_sockd_user

IFACE="$(ip route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"

cp "${DANTE_CONFIG}" "${DANTE_CONFIG}.bak.$(date +%s)" 2>/dev/null || true

cat >"${DANTE_CONFIG}" <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${PROXY_PORT}
external: ${IFACE}

user.privileged: root
user.unprivileged: sockd
user.libwrap: sockd

socksmethod: none
clientmethod: none

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error connect disconnect
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: connect
  log: error connect disconnect
}
EOF

open_firewall_port

systemctl enable "${DANTE_SERVICE}"
systemctl restart "${DANTE_SERVICE}"

SERVER_HOST="$(endpoint_host)"

printf '\nDone.\n'
printf 'SOCKS5 endpoint\n'
printf '%s:%s\n' "${SERVER_HOST:-SERVER_IP}" "${PROXY_PORT}"
printf 'Test with:\n'
printf 'curl --proxy socks5h://%s:%s https://ifconfig.me\n' "${SERVER_HOST:-SERVER_IP}" "${PROXY_PORT}"
