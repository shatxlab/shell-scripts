#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[browser-setup]"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OS_TYPE=""
PKG_MANAGER=""
STATE_DIR="$HOME/.local/state/shell-scripts"
STATE_FILE="$STATE_DIR/browser.env"

BROWSER_DOMAIN="${BROWSER_DOMAIN:-${1:-}}"
BROWSER_AUTH_USER="${BROWSER_AUTH_USER:-$USER}"
BROWSER_AUTH_PASSWORD="${BROWSER_AUTH_PASSWORD:-}"
BROWSER_SERVICE_NAME="browser"
BROWSER_USER="browser"
BROWSER_HOME="/var/lib/browser"
BROWSER_MEMORY_MAX="${BROWSER_MEMORY_MAX:-4G}"
BROWSER_DISPLAY_NUM=":14"
BROWSER_XVFB_RESOLUTION="1440x900x24"
BROWSER_VNC_PORT="5900"
BROWSER_NOVNC_PORT="6080"
BROWSER_START_URL="${BROWSER_START_URL:-about:blank}"

CADDY_MAIN_CONFIG="/etc/caddy/Caddyfile"
CADDY_IMPORT_LINE="import /etc/caddy/conf.d/*.caddy"
CADDY_SNIPPET_DIR="/etc/caddy/conf.d"
CADDY_SNIPPET_FILE="$CADDY_SNIPPET_DIR/browser.caddy"
SERVICE_FILE="/etc/systemd/system/$BROWSER_SERVICE_NAME.service"
LAUNCHER_FILE="/usr/local/bin/browser-session.sh"

BROWSER_USER_CREATED_BY_SCRIPT=0
BACKUP_CADDY_MAIN_CONFIG=""
BACKUP_CADDY_SNIPPET_FILE=""
BACKUP_SERVICE_FILE=""
BACKUP_LAUNCHER_FILE=""

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  have_cmd "$1" || die "Missing required command: $1"
}

ufw_bin_path() {
  local candidate

  if command -v ufw >/dev/null 2>&1; then
    command -v ufw
    return 0
  fi

  for candidate in /usr/sbin/ufw /sbin/ufw /usr/bin/ufw /bin/ufw; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_ufw_http_https() {
  local ufw_status ufw_bin

  ufw_bin="$(ufw_bin_path)" || {
    log "Skipping UFW rule update (ufw not installed)"
    return 0
  }

  ufw_status="$(sudo "$ufw_bin" status 2>/dev/null || true)"

  if ! printf '%s\n' "$ufw_status" | grep -Eq '(^|[[:space:]])80/tcp([[:space:]]|$)|(^|[[:space:]])80([[:space:]]|$)'; then
    log "Allowing 80/tcp in ufw"
    sudo "$ufw_bin" allow 80/tcp >/dev/null
  fi

  if ! printf '%s\n' "$ufw_status" | grep -Eq '(^|[[:space:]])443/tcp([[:space:]]|$)|(^|[[:space:]])443([[:space:]]|$)'; then
    log "Allowing 443/tcp in ufw"
    sudo "$ufw_bin" allow 443/tcp >/dev/null
  fi
}

wait_for_apt_locks() {
  local lock_paths=('/var/lib/dpkg/lock-frontend' '/var/lib/dpkg/lock' '/var/lib/apt/lists/lock' '/var/cache/apt/archives/lock')
  local locked=0

  while :; do
    locked=0
    for lock_path in "${lock_paths[@]}"; do
      if sudo fuser "$lock_path" >/dev/null 2>&1; then
        locked=1
        break
      fi
    done

    [ "$locked" -eq 0 ] && return 0
    log "Waiting for apt/dpkg lock to clear"
    sleep 3
  done
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

save_state() {
  mkdir -p "$STATE_DIR"

  {
    printf 'BROWSER_USER_CREATED_BY_SCRIPT=%q\n' "$BROWSER_USER_CREATED_BY_SCRIPT"
    printf 'BACKUP_CADDY_MAIN_CONFIG=%q\n' "$BACKUP_CADDY_MAIN_CONFIG"
    printf 'BACKUP_CADDY_SNIPPET_FILE=%q\n' "$BACKUP_CADDY_SNIPPET_FILE"
    printf 'BACKUP_SERVICE_FILE=%q\n' "$BACKUP_SERVICE_FILE"
    printf 'BACKUP_LAUNCHER_FILE=%q\n' "$BACKUP_LAUNCHER_FILE"
  } > "$STATE_FILE"
}

backup_if_exists() {
  local var_name="$1"
  local path="$2"
  local current backup

  eval "current=\${$var_name:-}"
  if [ -n "$current" ] && [ -e "$current" ]; then
    return 0
  fi

  if [ -f "$path" ]; then
    backup="${path}.bak-${TIMESTAMP}"
    cp "$path" "$backup"
    eval "$var_name=\$backup"
    log "Backed up $path -> $backup"
    save_state
  fi
}

sudo_backup_if_exists() {
  local var_name="$1"
  local path="$2"
  local current backup

  eval "current=\${$var_name:-}"
  if [ -n "$current" ] && sudo test -e "$current"; then
    return 0
  fi

  if sudo test -f "$path"; then
    backup="${path}.bak-${TIMESTAMP}"
    sudo cp "$path" "$backup"
    eval "$var_name=\$backup"
    log "Backed up $path -> $backup"
    save_state
  fi
}

restore_or_remove() {
  local backup="$1"
  local target="$2"

  if [ -n "$backup" ] && sudo test -e "$backup"; then
    sudo rm -rf "$target"
    sudo mv "$backup" "$target"
    log "Restored $target"
    return 0
  fi

  sudo rm -rf "$target"
  log "Removed $target"
}

verify_restored_or_removed() {
  local backup="$1"
  local target="$2"

  if [ -n "$backup" ]; then
    sudo test ! -e "$backup" || die "Backup still exists after uninstall: $backup"
    sudo test -e "$target" || die "Expected restored path is missing after uninstall: $target"
    return 0
  fi

  sudo test ! -e "$target" || die "Managed path still exists after uninstall: $target"
}

detect_env() {
  case "$(uname -s)" in
    Linux) OS_TYPE="linux" ;;
    Darwin) die "This script configures a Linux server with systemd and Caddy. macOS is not supported." ;;
    *) die "Unsupported OS. This script supports Linux only." ;;
  esac

  if have_cmd apt-get; then
    PKG_MANAGER="apt"
  elif have_cmd pacman; then
    PKG_MANAGER="pacman"
  elif have_cmd dnf; then
    PKG_MANAGER="dnf"
  else
    die "Unsupported package manager. Supported: apt, pacman, dnf"
  fi
}

ensure_requirements() {
  [ "$(id -u)" -ne 0 ] || die "Run as a normal user (it will use sudo when needed)."
  need_cmd sudo
  need_cmd systemctl
  need_cmd curl
  need_cmd mktemp
  [ -n "$BROWSER_DOMAIN" ] || die "Usage: BROWSER_DOMAIN=browser.example.com ./browser.sh or ./browser.sh browser.example.com"
}

install_caddy() {
  if have_cmd caddy; then
    log "caddy already installed"
    return 0
  fi

  case "$PKG_MANAGER" in
    apt)
      log "Installing caddy via apt"
      wait_for_apt_locks
      sudo apt-get update
      wait_for_apt_locks
      sudo apt-get install -y caddy
      ;;
    pacman)
      log "Installing caddy via pacman"
      sudo pacman -Sy --noconfirm caddy
      ;;
    dnf)
      log "Installing caddy via dnf"
      sudo dnf install -y caddy
      ;;
  esac
}

install_browser_packages() {
  case "$PKG_MANAGER" in
    apt)
      if ! have_cmd google-chrome-stable; then
        local tmp_source
        tmp_source="$(mktemp)"
        cat > "$tmp_source" <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main
EOF

        sudo mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
        sudo wget -qO- "https://dl.google.com/linux/linux_signing_key.pub" | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
        sudo install -m 644 "$tmp_source" /etc/apt/sources.list.d/google-chrome.list
        rm -f "$tmp_source"
      fi

      log "Installing remote browser stack via apt"
      wait_for_apt_locks
      sudo apt-get update
      wait_for_apt_locks
      sudo apt-get install -y google-chrome-stable novnc websockify x11vnc openbox dbus-x11 xvfb
      ;;
    pacman)
      log "Installing remote browser stack via pacman"
      sudo pacman -Sy --noconfirm chromium xorg-server-xvfb x11vnc openbox novnc websockify
      ;;
    dnf)
      log "Installing remote browser stack via dnf"
      sudo dnf install -y chromium xorg-x11-server-Xvfb x11vnc openbox novnc python3-websockify
      ;;
  esac
}

prompt_for_password() {
  local label="$1"
  local password_var_name="$2"
  local password confirm

  if [ -n "${!password_var_name}" ]; then
    return 0
  fi

  printf '%s Enter %s password: ' "$LOG_PREFIX" "$label" >&2
  read -r -s password
  printf '\n' >&2
  printf '%s Confirm password: ' "$LOG_PREFIX" >&2
  read -r -s confirm
  printf '\n' >&2

  [ -n "$password" ] || die "Password cannot be empty"
  [ "$password" = "$confirm" ] || die "Passwords did not match"

  printf -v "$password_var_name" '%s' "$password"
}

ensure_password_hash() {
  prompt_for_password "Caddy basic auth for $BROWSER_AUTH_USER" BROWSER_AUTH_PASSWORD

  BROWSER_AUTH_PASSWORD="$(caddy hash-password --plaintext "$BROWSER_AUTH_PASSWORD")"
}

ensure_browser_user() {
  if id "$BROWSER_USER" >/dev/null 2>&1; then
    log "Browser user already exists: $BROWSER_USER"
  else
    sudo useradd --system --create-home --home-dir "$BROWSER_HOME" --shell /usr/sbin/nologin "$BROWSER_USER"
    BROWSER_USER_CREATED_BY_SCRIPT=1
    save_state
    log "Created browser user: $BROWSER_USER"
  fi

  sudo mkdir -p "$BROWSER_HOME/logs" "$BROWSER_HOME/profile"
  sudo chown -R "$BROWSER_USER:$BROWSER_USER" "$BROWSER_HOME"
}

ensure_caddy_import() {
  local tmp_file
  tmp_file="$(mktemp)"

  if sudo test -f "$CADDY_MAIN_CONFIG"; then
    if sudo grep -Fqx "$CADDY_IMPORT_LINE" "$CADDY_MAIN_CONFIG"; then
      rm -f "$tmp_file"
      log "Caddy import already present in $CADDY_MAIN_CONFIG"
      return 0
    fi

    sudo_backup_if_exists BACKUP_CADDY_MAIN_CONFIG "$CADDY_MAIN_CONFIG"
    sudo cat "$CADDY_MAIN_CONFIG" > "$tmp_file"
    printf '\n%s\n' "$CADDY_IMPORT_LINE" >> "$tmp_file"
  else
    printf '%s\n' "$CADDY_IMPORT_LINE" > "$tmp_file"
  fi

  sudo install -D -m 0644 "$tmp_file" "$CADDY_MAIN_CONFIG"
  rm -f "$tmp_file"
  log "Updated $CADDY_MAIN_CONFIG"
}

write_launcher() {
  local tmp_file chrome_cmd
  tmp_file="$(mktemp)"

  if have_cmd google-chrome-stable; then
    chrome_cmd="google-chrome-stable"
  elif have_cmd chromium; then
    chrome_cmd="chromium"
  else
    chrome_cmd="chromium-browser"
  fi

  cat > "$tmp_file" <<EOF
#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="\${DISPLAY_NUM:-$BROWSER_DISPLAY_NUM}"
DISPLAY_SOCKET="\${DISPLAY_NUM#:}"
HOME_DIR="\${HOME:-$BROWSER_HOME}"
LOG_DIR="\$HOME_DIR/logs"
PROFILE_DIR="\$HOME_DIR/profile"
XVFB_RESOLUTION="\${XVFB_RESOLUTION:-$BROWSER_XVFB_RESOLUTION}"
VNC_PORT="\${VNC_PORT:-$BROWSER_VNC_PORT}"
NOVNC_PORT="\${NOVNC_PORT:-$BROWSER_NOVNC_PORT}"
START_URL="\${START_URL:-$BROWSER_START_URL}"

mkdir -p "\$LOG_DIR" "\$PROFILE_DIR"

cleanup() {
  for pid in \${CHROME_PID:-} \${NOVNC_PID:-} \${VNC_PID:-} \${OPENBOX_PID:-} \${XVFB_PID:-}; do
    if [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then
      kill "\$pid" 2>/dev/null || true
      wait "\$pid" 2>/dev/null || true
    fi
  done
}

trap cleanup EXIT INT TERM

rm -f "/tmp/.X\${DISPLAY_SOCKET}-lock"

Xvfb "\$DISPLAY_NUM" -screen 0 "\$XVFB_RESOLUTION" -nolisten tcp -ac >"\$LOG_DIR/xvfb.log" 2>&1 &
XVFB_PID=\$!

for _ in \$(seq 1 50); do
  if [ -S "/tmp/.X11-unix/X\${DISPLAY_SOCKET}" ]; then
    break
  fi
  sleep 0.2
done

if [ ! -S "/tmp/.X11-unix/X\${DISPLAY_SOCKET}" ]; then
  echo "Xvfb did not start" >&2
  exit 1
fi

export DISPLAY="\$DISPLAY_NUM"

openbox >"\$LOG_DIR/openbox.log" 2>&1 &
OPENBOX_PID=\$!

x11vnc -display "\$DISPLAY_NUM" -rfbport "\$VNC_PORT" -localhost -forever -shared -nopw -xkb -noxdamage -wait 10 -defer 10 -threads >"\$LOG_DIR/x11vnc.log" 2>&1 &
VNC_PID=\$!

websockify --web /usr/share/novnc 127.0.0.1:"\$NOVNC_PORT" 127.0.0.1:"\$VNC_PORT" >"\$LOG_DIR/websockify.log" 2>&1 &
NOVNC_PID=\$!

  $chrome_cmd \
  --user-data-dir="\$PROFILE_DIR" \
  --password-store=basic \
  --no-first-run \
  --no-default-browser-check \
  --force-dark-mode \
  --enable-features=WebUIDarkMode \
  --disable-smooth-scrolling \
  --disable-features=UseSkiaRenderer \
  --disable-dev-shm-usage \
  --disable-gpu \
  --window-size=1440,900 \
  --new-window \
  "\$START_URL" >"\$LOG_DIR/chrome.log" 2>&1 &
CHROME_PID=\$!

wait -n "\$XVFB_PID" "\$OPENBOX_PID" "\$VNC_PID" "\$NOVNC_PID" "\$CHROME_PID"
exit 1
EOF

  sudo_backup_if_exists BACKUP_LAUNCHER_FILE "$LAUNCHER_FILE"
  sudo install -m 0755 "$tmp_file" "$LAUNCHER_FILE"
  rm -f "$tmp_file"
  log "Written $LAUNCHER_FILE"
}

write_service() {
  local tmp_file
  tmp_file="$(mktemp)"

  cat > "$tmp_file" <<EOF
[Unit]
Description=Remote browser session
After=network.target

[Service]
Type=simple
User=$BROWSER_USER
Group=$BROWSER_USER
WorkingDirectory=$BROWSER_HOME
Environment=HOME=$BROWSER_HOME
Environment=DISPLAY_NUM=$BROWSER_DISPLAY_NUM
Environment=XVFB_RESOLUTION=$BROWSER_XVFB_RESOLUTION
Environment=VNC_PORT=$BROWSER_VNC_PORT
Environment=NOVNC_PORT=$BROWSER_NOVNC_PORT
Environment=START_URL=$BROWSER_START_URL
ExecStart=$LAUNCHER_FILE
Restart=always
RestartSec=5
RuntimeDirectory=$BROWSER_SERVICE_NAME
MemoryMax=$BROWSER_MEMORY_MAX
TasksMax=256
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$BROWSER_HOME /tmp

[Install]
WantedBy=multi-user.target
EOF

  sudo_backup_if_exists BACKUP_SERVICE_FILE "$SERVICE_FILE"
  sudo install -m 0644 "$tmp_file" "$SERVICE_FILE"
  rm -f "$tmp_file"
  log "Written $SERVICE_FILE"
}

write_caddy_snippet() {
  local tmp_file
  tmp_file="$(mktemp)"

  cat > "$tmp_file" <<EOF
$BROWSER_DOMAIN {
  route {
    basicauth {
      $BROWSER_AUTH_USER $BROWSER_AUTH_PASSWORD
    }

    @root path /
    redir @root /vnc.html?autoconnect=1&resize=remote 302

    reverse_proxy 127.0.0.1:$BROWSER_NOVNC_PORT
  }
}
EOF

  sudo mkdir -p "$CADDY_SNIPPET_DIR"
  sudo_backup_if_exists BACKUP_CADDY_SNIPPET_FILE "$CADDY_SNIPPET_FILE"
  sudo install -m 0644 "$tmp_file" "$CADDY_SNIPPET_FILE"
  rm -f "$tmp_file"
  log "Written $CADDY_SNIPPET_FILE"
}

enable_services() {
  log "Reloading systemd units"
  sudo systemctl daemon-reload

  log "Enabling browser service"
  sudo systemctl enable --now "$BROWSER_SERVICE_NAME"

  log "Enabling caddy"
  sudo systemctl enable --now caddy
}

reload_caddy() {
  log "Validating Caddy configuration"
  sudo caddy validate --config "$CADDY_MAIN_CONFIG"

  log "Reloading caddy"
  sudo systemctl reload caddy
}

verify_setup() {
  local browser_cmd=""

  if have_cmd google-chrome-stable; then
    browser_cmd="$(google-chrome-stable --version)"
  elif have_cmd chromium; then
    browser_cmd="$(chromium --version)"
  else
    browser_cmd="$(chromium-browser --version)"
  fi

  printf '%s Verification\n' "$LOG_PREFIX"
  printf '  %-20s %s\n' "browser" "$browser_cmd"
  printf '  %-20s %s\n' "caddy" "$(caddy version)"
  printf '  %-20s %s\n' "domain" "$BROWSER_DOMAIN"
  printf '  %-20s %s\n' "memory max" "$BROWSER_MEMORY_MAX"
  printf '  %-20s %s\n' "service" "$BROWSER_SERVICE_NAME"

  sudo systemctl --no-pager --lines=0 status "$BROWSER_SERVICE_NAME"
  sudo systemctl --no-pager --lines=0 status caddy
}

cleanup_managed_files() {
  restore_or_remove "$BACKUP_SERVICE_FILE" "$SERVICE_FILE"
  restore_or_remove "$BACKUP_LAUNCHER_FILE" "$LAUNCHER_FILE"
  restore_or_remove "$BACKUP_CADDY_SNIPPET_FILE" "$CADDY_SNIPPET_FILE"
  restore_or_remove "$BACKUP_CADDY_MAIN_CONFIG" "$CADDY_MAIN_CONFIG"
}

terminate_browser_user_processes() {
  if ! id "$BROWSER_USER" >/dev/null 2>&1; then
    return 0
  fi

  if ! sudo pgrep -u "$BROWSER_USER" >/dev/null 2>&1; then
    return 0
  fi

  log "Terminating remaining processes for $BROWSER_USER"
  sudo pkill -TERM -u "$BROWSER_USER" >/dev/null 2>&1 || true

  for _ in $(seq 1 20); do
    if ! sudo pgrep -u "$BROWSER_USER" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  log "Force killing remaining processes for $BROWSER_USER"
  sudo pkill -KILL -u "$BROWSER_USER" >/dev/null 2>&1 || true

  for _ in $(seq 1 10); do
    if ! sudo pgrep -u "$BROWSER_USER" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done

  die "Processes are still running for $BROWSER_USER; refusing to remove the user"
}

remove_browser_user_if_tracked() {
  if [ "$BROWSER_USER_CREATED_BY_SCRIPT" != "1" ]; then
    log "Skipping browser user removal (not created by this script)"
    return 0
  fi

  if id "$BROWSER_USER" >/dev/null 2>&1; then
    terminate_browser_user_processes
    sudo userdel -r "$BROWSER_USER" >/dev/null 2>&1 || sudo userdel "$BROWSER_USER"
    log "Removed browser user: $BROWSER_USER"
  fi
}

disable_services() {
  log "Stopping browser service"
  sudo systemctl disable --now "$BROWSER_SERVICE_NAME" >/dev/null 2>&1 || true

  if id "$BROWSER_USER" >/dev/null 2>&1; then
    for _ in $(seq 1 20); do
      if ! sudo pgrep -u "$BROWSER_USER" >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
    done
  fi

  sudo systemctl daemon-reload
  if sudo test -f "$CADDY_MAIN_CONFIG"; then
    sudo caddy validate --config "$CADDY_MAIN_CONFIG"
    sudo systemctl reload caddy >/dev/null 2>&1 || true
  fi
}

verify_uninstall() {
  log "Verifying uninstall"

  verify_restored_or_removed "$BACKUP_SERVICE_FILE" "$SERVICE_FILE"
  verify_restored_or_removed "$BACKUP_LAUNCHER_FILE" "$LAUNCHER_FILE"
  verify_restored_or_removed "$BACKUP_CADDY_SNIPPET_FILE" "$CADDY_SNIPPET_FILE"
  verify_restored_or_removed "$BACKUP_CADDY_MAIN_CONFIG" "$CADDY_MAIN_CONFIG"

  if [ "$BROWSER_USER_CREATED_BY_SCRIPT" = "1" ] && id "$BROWSER_USER" >/dev/null 2>&1; then
    die "Browser user still exists after uninstall: $BROWSER_USER"
  fi

  [ ! -e "$STATE_FILE" ] || die "State file still exists after uninstall: $STATE_FILE"
}

uninstall_all() {
  [ "$(id -u)" -ne 0 ] || die "Run as a normal user (not root)."

  if [ ! -f "$STATE_FILE" ]; then
    die "No install state found at $STATE_FILE. Refusing to guess what to remove."
  fi

  load_state
  disable_services
  cleanup_managed_files
  remove_browser_user_if_tracked
  rm -f "$STATE_FILE"
  verify_uninstall

  echo
  log "Uninstall complete. Removed everything tracked from the browser setup."
}

main() {
  case "${1:-install}" in
    ''|install)
      detect_env
      ensure_requirements
      load_state
      install_caddy
      install_browser_packages
      ensure_password_hash
      ensure_browser_user
      ensure_caddy_import
      write_launcher
      write_service
      write_caddy_snippet
      ensure_ufw_http_https
      enable_services
      reload_caddy
      verify_setup

      cat <<EOF

$LOG_PREFIX Done.
$LOG_PREFIX Open https://$BROWSER_DOMAIN
$LOG_PREFIX The browser runs as '$BROWSER_USER' with a memory cap of $BROWSER_MEMORY_MAX.
$LOG_PREFIX Re-run this script any time to re-apply the same browser service and Caddy proxy.
EOF
      ;;
    install)
      detect_env
      ensure_requirements
      load_state
      install_caddy
      install_browser_packages
      ensure_password_hash
      ensure_browser_user
      ensure_caddy_import
      write_launcher
      write_service
      write_caddy_snippet
      ensure_ufw_http_https
      enable_services
      reload_caddy
      verify_setup

      cat <<EOF

$LOG_PREFIX Done.
$LOG_PREFIX Open https://$BROWSER_DOMAIN
$LOG_PREFIX The browser runs as '$BROWSER_USER' with a memory cap of $BROWSER_MEMORY_MAX.
$LOG_PREFIX Re-run this script any time to re-apply the same browser service and Caddy proxy.
EOF
      ;;
    uninstall)
      detect_env
      uninstall_all
      ;;
    *)
      detect_env
      ensure_requirements
      load_state
      install_caddy
      install_browser_packages
      ensure_password_hash
      ensure_browser_user
      ensure_caddy_import
      write_launcher
      write_service
      write_caddy_snippet
      ensure_ufw_http_https
      enable_services
      reload_caddy
      verify_setup

      cat <<EOF

$LOG_PREFIX Done.
$LOG_PREFIX Open https://$BROWSER_DOMAIN
$LOG_PREFIX The browser runs as '$BROWSER_USER' with a memory cap of $BROWSER_MEMORY_MAX.
$LOG_PREFIX Re-run this script any time to re-apply the same browser service and Caddy proxy.
EOF
      ;;
  esac
}

main "$@"
