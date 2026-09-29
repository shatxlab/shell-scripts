#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[bootstrap-vps]"

SERVER_IP="${SERVER_IP:-${1:-}}"
EXISTING_USER="${EXISTING_USER:-}"
USERNAME="${EXISTING_USER:-${USERNAME:-${2:-}}}"
KEY_NAME="${KEY_NAME:-${USERNAME:-vps}-${SERVER_IP:-server}}"
KEY_PATH="$HOME/.ssh/$KEY_NAME"
SERVER_PORT="2233"
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  have_cmd "$1" || die "Missing required command: $1"
}

ensure_requirements() {
  [ -n "$SERVER_IP" ] || die "Set SERVER_IP to the VPS address"
  [ -n "$USERNAME" ] || die "Set USERNAME to the new sudo user or EXISTING_USER to an existing sudo user"
  [ "$(id -u)" -ne 0 ] || die "Run this script as your normal local user, not as root"

  need_cmd ssh
  need_cmd ssh-keygen
  need_cmd grep
  need_cmd mktemp
  need_cmd chmod
  need_cmd mkdir
}

ensure_local_key() {
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  if [ -f "$KEY_PATH" ]; then
    log "Using existing SSH key: $KEY_PATH"
    return 0
  fi

  log "Generating SSH key: $KEY_PATH"
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "$KEY_NAME"
}

read_public_key() {
  [ -f "${KEY_PATH}.pub" ] || die "Missing public key: ${KEY_PATH}.pub"
  tr -d '\n' < "${KEY_PATH}.pub"
}

restart_sshd_snippet() {
  cat <<'EOF'
restart_sshd() {
  if [ "$(id -u)" -eq 0 ] && [ -d /run ]; then
    install -d -m 0755 /run/sshd
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
      systemctl disable --now ssh.socket >/dev/null 2>&1 || true
      systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
      systemctl start ssh >/dev/null 2>&1 || systemctl start sshd >/dev/null 2>&1 || true
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart ssh >/dev/null 2>&1; then
      return 0
    fi
    if systemctl restart sshd >/dev/null 2>&1; then
      return 0
    fi
  fi

  if service ssh restart >/dev/null 2>&1; then
    return 0
  fi
  if service sshd restart >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

wait_for_apt_locks() {
  local lock_paths=('/var/lib/dpkg/lock-frontend' '/var/lib/dpkg/lock' '/var/lib/apt/lists/lock' '/var/cache/apt/archives/lock')
  local locked=0

  if ! command -v fuser >/dev/null 2>&1; then
    return 0
  fi

  while :; do
    locked=0
    for lock_path in "${lock_paths[@]}"; do
      if fuser "$lock_path" >/dev/null 2>&1; then
        locked=1
        break
      fi
    done

    [ "$locked" -eq 0 ] && return 0
    printf '[bootstrap-vps] Waiting for apt/dpkg lock to clear\n' >&2
    sleep 3
  done
}
EOF
}

run_root_phase() {
  local login_user
  local remote_command
  local ssh_pubkey
  local sudo_password
  local ssh_port

  ssh_pubkey="$(read_public_key)"

  if [ -n "$EXISTING_USER" ]; then
    login_user="$EXISTING_USER"
    remote_command="sudo -n bash -s -- '$USERNAME' '$ssh_pubkey' '$SERVER_PORT' '1'"
  else
    login_user="root"
    remote_command="bash -s -- '$USERNAME' '$ssh_pubkey' '$SERVER_PORT' '0'"
  fi

  log "Connecting as ${login_user}@${SERVER_IP} to prepare the server (trying ports 22 then 2233)"

  if [ -z "$EXISTING_USER" ]; then
    for ssh_port in 22 2233; do
      if remote_root_phase_script | ssh -p "$ssh_port" "${SSH_OPTS[@]}" "$login_user@$SERVER_IP" "$remote_command"; then
        return 0
      fi
    done
    die "Unable to connect as ${login_user}@${SERVER_IP} on ports 22 or 2233"
  fi

  for ssh_port in 22 2233; do
    if ssh -p "$ssh_port" "${SSH_OPTS[@]}" "$login_user@$SERVER_IP" "sudo -n true"; then
      remote_root_phase_script | ssh -p "$ssh_port" "${SSH_OPTS[@]}" "$login_user@$SERVER_IP" "$remote_command"
      return 0
    fi
  done

  printf 'Remote sudo password for %s@%s: ' "$login_user" "$SERVER_IP" > /dev/tty
  IFS= read -r -s sudo_password < /dev/tty
  printf '\n' > /dev/tty

  for ssh_port in 22 2233; do
    if {
      printf '%s\n' "$sudo_password"
      remote_root_phase_script
    } | ssh -p "$ssh_port" "${SSH_OPTS[@]}" "$login_user@$SERVER_IP" \
      "sudo -S -p '' bash -s -- '$USERNAME' '$ssh_pubkey' '$SERVER_PORT' '1'"; then
      unset sudo_password
      return 0
    fi
  done

  unset sudo_password
  die "Unable to connect as ${login_user}@${SERVER_IP} on ports 22 or 2233"
}

remote_root_phase_script() {
  cat <<EOF
set -euo pipefail

USERNAME="\$1"
SSH_PUBKEY="\$2"
SERVER_PORT="\$3"
SKIP_USER_CREATION="\$4"

$(restart_sshd_snippet)

export DEBIAN_FRONTEND=noninteractive

wait_for_apt_locks
apt-get update
wait_for_apt_locks
apt-get upgrade -y

missing_packages=""
for package_name in sudo ufw psmisc ca-certificates; do
  if ! dpkg-query -W -f='\${Status}' "\$package_name" 2>/dev/null | grep -q "install ok installed"; then
    missing_packages="\$missing_packages \$package_name"
  fi
done

if [ -n "\$missing_packages" ]; then
  printf 'Installing required packages:%s\n' "\$missing_packages" >&2
  wait_for_apt_locks
  apt-get install -y \$missing_packages
fi

command -v sudo >/dev/null 2>&1 || {
  printf 'Missing required command after install: sudo\n' >&2
  exit 1
}

command -v ufw >/dev/null 2>&1 || {
  printf 'Missing required command after install: ufw\n' >&2
  exit 1
}

if [ "\$SKIP_USER_CREATION" != "1" ]; then
  if ! id -u "\$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "\$USERNAME"
  else
    usermod -aG sudo "\$USERNAME"
  fi
fi

install -d -m 700 -o "\$USERNAME" -g "\$USERNAME" "/home/\$USERNAME/.ssh"
touch "/home/\$USERNAME/.ssh/authorized_keys"
grep -qxF "\$SSH_PUBKEY" "/home/\$USERNAME/.ssh/authorized_keys" || printf '%s\n' "\$SSH_PUBKEY" >> "/home/\$USERNAME/.ssh/authorized_keys"
chown "\$USERNAME:\$USERNAME" "/home/\$USERNAME/.ssh/authorized_keys"
chmod 600 "/home/\$USERNAME/.ssh/authorized_keys"

printf '%s\n' "\$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-\$USERNAME"
chmod 440 "/etc/sudoers.d/90-\$USERNAME"

install -d /etc/ssh/sshd_config.d
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' /etc/ssh/sshd_config; then
  tmp_file="\$(mktemp)"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "\$tmp_file"
  cat /etc/ssh/sshd_config >> "\$tmp_file"
  cat "\$tmp_file" > /etc/ssh/sshd_config
  rm -f "\$tmp_file"
fi

cat > /etc/ssh/sshd_config.d/99-bootstrap.conf <<CONF
Port 22
Port \$SERVER_PORT
PubkeyAuthentication yes
CONF

install -d -m 0755 /run/sshd
sshd -t

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow "\$SERVER_PORT"/tcp
ufw --force enable

restart_sshd || {
  printf 'Failed to restart ssh service\n' >&2
  exit 1
}
EOF
}

verify_new_login() {
  log "Verifying ${USERNAME}@${SERVER_IP}:${SERVER_PORT} with the new key"

  ssh -i "$KEY_PATH" -p "$SERVER_PORT" "${SSH_OPTS[@]}" \
    "$USERNAME@$SERVER_IP" "echo Connection successful"
}

run_hardening_phase() {
  log "Hardening SSH after key login verification"

  ssh -i "$KEY_PATH" -p "$SERVER_PORT" "${SSH_OPTS[@]}" \
    "$USERNAME@$SERVER_IP" "bash -s -- '$SERVER_PORT'" <<EOF
set -euo pipefail

SERVER_PORT="\$1"

$(restart_sshd_snippet)

sudo sed -i -E '/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)[[:space:]]+/ s/^/# managed-by-bootstrap /' /etc/ssh/sshd_config

sudo install -d /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/99-bootstrap.conf >/dev/null <<CONF
Port \$SERVER_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
CONF

sudo install -d -m 0755 /run/sshd
sudo sshd -t
sudo ufw delete allow 22/tcp >/dev/null 2>&1 || true
sudo ufw allow "\$SERVER_PORT"/tcp >/dev/null 2>&1 || true

sudo bash -s <<'SUDOEOF'
$(restart_sshd_snippet)
restart_sshd
SUDOEOF
if [ "\$?" -ne 0 ]; then
  printf 'Failed to restart ssh service\n' >&2
  exit 1
fi
EOF
}

write_ssh_config_alias() {
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"

  if grep -q "^Host $KEY_NAME$" "$SSH_CONFIG"; then
    log "SSH config alias $KEY_NAME already exists; leaving it unchanged"
    return 0
  fi

  printf '\nHost %s\n    HostName %s\n    User %s\n    Port %s\n    IdentityFile %s\n    IdentitiesOnly yes\n    SetEnv TERM=xterm-256color\n    ServerAliveInterval 30\n    ServerAliveCountMax 3\n' \
    "$KEY_NAME" "$SERVER_IP" "$USERNAME" "$SERVER_PORT" "$KEY_PATH" >> "$SSH_CONFIG"

  log "Added SSH config alias: $KEY_NAME"
}

verify_final_login() {
  log "Verifying the final key-only SSH login"

  ssh -i "$KEY_PATH" -p "$SERVER_PORT" "${SSH_OPTS[@]}" \
    "$USERNAME@$SERVER_IP" "echo Final key-only connection successful"
}

main() {
  ensure_requirements
  ensure_local_key
  run_root_phase
  verify_new_login
  run_hardening_phase
  verify_final_login
  write_ssh_config_alias
  log "Provisioning complete. Connect with: ssh $KEY_NAME"
}

main "$@"
