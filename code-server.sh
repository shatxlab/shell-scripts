#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[code-server-setup]"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OS_TYPE=""
PKG_MANAGER=""
STATE_DIR="$HOME/.local/state/shell-scripts"
STATE_FILE="$STATE_DIR/code-server.env"

CODE_SERVER_DOMAIN="${CODE_SERVER_DOMAIN:-${1:-}}"
CODE_SERVER_AUTH_USER="${CODE_SERVER_AUTH_USER:-$USER}"
CODE_SERVER_AUTH_PASSWORD="${CODE_SERVER_AUTH_PASSWORD:-}"
CODE_SERVER_BIND_ADDR="127.0.0.1:8080"
CODE_SERVER_PORT_PROXY_URI="https://{{port}}.${CODE_SERVER_DOMAIN}"
CODE_SERVER_ALLOWLIST_PORT="9123"
CODE_SERVER_KEEP_PACKAGE="${CODE_SERVER_KEEP_PACKAGE:-0}"
CODE_SERVER_KEEP_CADDY="${CODE_SERVER_KEEP_CADDY:-0}"

CONFIG_DIR="$HOME/.config/code-server"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SETTINGS_DIR="$HOME/.local/share/code-server/User"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
EXTENSIONS_DIR="$HOME/.local/share/code-server/extensions"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/code-server@$USER.service.d"
SYSTEMD_OVERRIDE_FILE="$SYSTEMD_OVERRIDE_DIR/override.conf"
CODE_SERVER_SERVICE="code-server@$USER"
CODE_SERVER_UNIT="/usr/lib/systemd/system/code-server@.service"
CODE_SERVER_BIN="/usr/bin/code-server"
ALLOWLIST_DOMAIN_REGEX=""

CADDY_MAIN_CONFIG="/etc/caddy/Caddyfile"
CADDY_IMPORT_LINE="import /etc/caddy/conf.d/*.caddy"
CADDY_SNIPPET_DIR="/etc/caddy/conf.d"
CADDY_SNIPPET_FILE="$CADDY_SNIPPET_DIR/code-server.caddy"

EXTENSIONS=(
  "cedricverlinden.cursor-dark"
  "ms-playwright.playwright"
)

CADDY_INSTALLED_BY_SCRIPT=0
CADDY_STATE_TRACKED=0
CODE_SERVER_INSTALLED_BY_SCRIPT=0
EXTENSIONS_INSTALLED_BY_SCRIPT=""
BACKUP_CONFIG_FILE=""
BACKUP_SETTINGS_FILE=""
BACKUP_OVERRIDE_FILE=""
BACKUP_CADDY_MAIN_CONFIG=""
BACKUP_CADDY_SNIPPET_FILE=""

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

cleanup_empty_dir() {
  local dir="$1"

  if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    rmdir "$dir"
  fi
}

sudo_cleanup_empty_dir() {
  local dir="$1"

  if sudo test -d "$dir" && [ -z "$(sudo ls -A "$dir" 2>/dev/null)" ]; then
    sudo rmdir "$dir"
  fi
}

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
    if grep -q '^CADDY_INSTALLED_BY_SCRIPT=' "$STATE_FILE"; then
      CADDY_STATE_TRACKED=1
    fi
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

save_state() {
  mkdir -p "$STATE_DIR"

  {
    printf 'CODE_SERVER_INSTALLED_BY_SCRIPT=%q\n' "$CODE_SERVER_INSTALLED_BY_SCRIPT"
    printf 'CADDY_INSTALLED_BY_SCRIPT=%q\n' "$CADDY_INSTALLED_BY_SCRIPT"
    printf 'EXTENSIONS_INSTALLED_BY_SCRIPT=%q\n' "$EXTENSIONS_INSTALLED_BY_SCRIPT"
    printf 'BACKUP_CONFIG_FILE=%q\n' "$BACKUP_CONFIG_FILE"
    printf 'BACKUP_SETTINGS_FILE=%q\n' "$BACKUP_SETTINGS_FILE"
    printf 'BACKUP_OVERRIDE_FILE=%q\n' "$BACKUP_OVERRIDE_FILE"
    printf 'BACKUP_CADDY_MAIN_CONFIG=%q\n' "$BACKUP_CADDY_MAIN_CONFIG"
    printf 'BACKUP_CADDY_SNIPPET_FILE=%q\n' "$BACKUP_CADDY_SNIPPET_FILE"
  } > "$STATE_FILE"
}

append_unique_word() {
  local value="$1"
  local current="$2"

  case " $current " in
    *" $value "*) printf '%s' "$current" ;;
    '') printf '%s' "$value" ;;
    *) printf '%s %s' "$current" "$value" ;;
  esac
}

track_extension_install() {
  EXTENSIONS_INSTALLED_BY_SCRIPT="$(append_unique_word "$1" "$EXTENSIONS_INSTALLED_BY_SCRIPT")"
  save_state
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
  local sudo_mode="$3"

  if [ -n "$backup" ]; then
    if [ "$sudo_mode" = "sudo" ]; then
      if sudo test -e "$backup"; then
        sudo rm -rf "$target"
        sudo mv "$backup" "$target"
        log "Restored $target"
        return 0
      fi
    else
      if [ -e "$backup" ]; then
        rm -rf "$target"
        mv "$backup" "$target"
        log "Restored $target"
        return 0
      fi
    fi
  fi

  if [ "$sudo_mode" = "sudo" ]; then
    sudo rm -rf "$target"
  else
    rm -rf "$target"
  fi
  log "Removed $target"
}

verify_restored_or_removed() {
  local backup="$1"
  local target="$2"
  local sudo_mode="$3"

  if [ -n "$backup" ]; then
    if [ "$sudo_mode" = "sudo" ]; then
      sudo test ! -e "$backup" || die "Backup still exists after uninstall: $backup"
      sudo test -e "$target" || die "Expected restored path is missing after uninstall: $target"
    else
      [ ! -e "$backup" ] || die "Backup still exists after uninstall: $backup"
      [ -e "$target" ] || die "Expected restored path is missing after uninstall: $target"
    fi
    return 0
  fi

  if [ "$sudo_mode" = "sudo" ]; then
    sudo test ! -e "$target" || die "Managed path still exists after uninstall: $target"
  else
    [ ! -e "$target" ] || die "Managed path still exists after uninstall: $target"
  fi
}

escape_regex() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'
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
  [ -n "$CODE_SERVER_DOMAIN" ] || die "Usage: CODE_SERVER_DOMAIN=dev.example.com ./code-server.sh or ./code-server.sh dev.example.com"

  ALLOWLIST_DOMAIN_REGEX="^($(escape_regex "$CODE_SERVER_DOMAIN")|[0-9]+\\.$(escape_regex "$CODE_SERVER_DOMAIN"))$"
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
      CADDY_INSTALLED_BY_SCRIPT=1
      save_state
      ;;
    pacman)
      log "Installing caddy via pacman"
      sudo pacman -Sy --noconfirm caddy
      CADDY_INSTALLED_BY_SCRIPT=1
      save_state
      ;;
    dnf)
      log "Installing caddy via dnf"
      sudo dnf install -y caddy
      CADDY_INSTALLED_BY_SCRIPT=1
      save_state
      ;;
    *)
      die "Unsupported package manager: $PKG_MANAGER"
      ;;
  esac
}

install_code_server() {
  if have_cmd code-server; then
    log "code-server already installed"
    return 0
  fi

  log "Installing code-server via official installer"
  curl -fsSL https://code-server.dev/install.sh | sh
  CODE_SERVER_INSTALLED_BY_SCRIPT=1
  save_state
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
  prompt_for_password "Caddy basic auth for $CODE_SERVER_AUTH_USER" CODE_SERVER_AUTH_PASSWORD

  CODE_SERVER_AUTH_PASSWORD="$(caddy hash-password --plaintext "$CODE_SERVER_AUTH_PASSWORD")"
}

write_code_server_config() {
  mkdir -p "$CONFIG_DIR"
  backup_if_exists BACKUP_CONFIG_FILE "$CONFIG_FILE"

  cat > "$CONFIG_FILE" <<EOF
bind-addr: $CODE_SERVER_BIND_ADDR
auth: none
cert: false
EOF

  log "Written $CONFIG_FILE"
}

write_code_server_settings() {
  mkdir -p "$SETTINGS_DIR"
  backup_if_exists BACKUP_SETTINGS_FILE "$SETTINGS_FILE"

  cat > "$SETTINGS_FILE" <<'EOF'
{
  "chat.agentsControl.enabled": false,
  "chat.commandCenter.enabled": false,
  "github.copilot.enable": {
    "*": false,
    "plaintext": false,
    "markdown": false,
    "scminput": false
  },
  "github.copilot.chat.enabled": false,
  "workbench.startupEditor": "none",
  "workbench.activityBar.location": "top",
  "workbench.layoutControl.enabled": false,
  "workbench.colorTheme": "cursor-dark",
  "editor.fontFamily": "'JetBrains Mono', monospace",
  "editor.wordWrap": "on",
  "editor.fontSize": 14,
  "editor.fontLigatures": false,
  "terminal.integrated.fontFamily": "'JetBrains Mono', monospace",
  "terminal.integrated.fontSize": 14,
  "terminal.integrated.lineHeight": 1,
  "terminal.integrated.letterSpacing": 0,
  "terminal.integrated.fontLigatures": false,
  "terminal.integrated.fontWeight": "normal",
  "terminal.integrated.fontWeightBold": "normal",
  "terminal.integrated.gpuAcceleration": "on",
  "editor.minimap.enabled": false,
  "diffEditor.renderSideBySide": false
}
EOF

  log "Written $SETTINGS_FILE"
}

install_extensions() {
  local extension installed
  installed="$(code-server --list-extensions 2>/dev/null || true)"

  for extension in "${EXTENSIONS[@]}"; do
    if printf '%s\n' "$installed" | grep -Fxq "$extension"; then
      log "Extension already installed: $extension"
      continue
    fi

    log "Installing extension: $extension"
    code-server --install-extension "$extension"
    track_extension_install "$extension"
  done
}

write_systemd_override() {
  local tmp_file
  tmp_file="$(mktemp)"

  cat > "$tmp_file" <<EOF
[Service]
Environment=VSCODE_PROXY_URI=$CODE_SERVER_PORT_PROXY_URI
ExecStart=
ExecStart=$CODE_SERVER_BIN --auth none --proxy-domain {{port}}.$CODE_SERVER_DOMAIN
EOF

  sudo mkdir -p "$SYSTEMD_OVERRIDE_DIR"
  sudo_backup_if_exists BACKUP_OVERRIDE_FILE "$SYSTEMD_OVERRIDE_FILE"
  sudo install -m 0644 "$tmp_file" "$SYSTEMD_OVERRIDE_FILE"
  rm -f "$tmp_file"
  log "Written $SYSTEMD_OVERRIDE_FILE"
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

  sudo install -m 0644 "$tmp_file" "$CADDY_MAIN_CONFIG"
  rm -f "$tmp_file"
  log "Updated $CADDY_MAIN_CONFIG"
}

write_caddy_snippet() {
  local tmp_file
  tmp_file="$(mktemp)"

  cat > "$tmp_file" <<EOF
$CODE_SERVER_DOMAIN {
  basicauth {
    $CODE_SERVER_AUTH_USER $CODE_SERVER_AUTH_PASSWORD
  }

  reverse_proxy $CODE_SERVER_BIND_ADDR {
    header_up Host {host}
  }
}

https:// {
  tls {
    on_demand
  }

  @forwarded vars_regexp forwarded {host} ^([0-9]+)\\.$(escape_regex "$CODE_SERVER_DOMAIN")$
  handle @forwarded {
    basicauth {
      $CODE_SERVER_AUTH_USER $CODE_SERVER_AUTH_PASSWORD
    }

    reverse_proxy localhost:{re.forwarded.1}
  }

  abort
}

http://127.0.0.1:$CODE_SERVER_ALLOWLIST_PORT {
  @allowed `{query.domain}.matches("$ALLOWLIST_DOMAIN_REGEX")`
  respond @allowed "ok" 200
  respond "forbidden" 403
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

  log "Enabling code-server systemd unit"
  sudo systemctl enable --now "$CODE_SERVER_SERVICE"

  log "Enabling caddy systemd unit"
  sudo systemctl enable --now caddy
}

reload_services() {
  log "Validating Caddy configuration"
  sudo caddy validate --config "$CADDY_MAIN_CONFIG"

  log "Restarting code-server"
  sudo systemctl restart "$CODE_SERVER_SERVICE"

  log "Reloading caddy"
  sudo systemctl reload caddy
}

verify_setup() {
  printf '%s Verification\n' "$LOG_PREFIX"
  printf '  %-20s %s\n' "code-server" "$(code-server --version | sed -n '1p')"
  printf '  %-20s %s\n' "caddy" "$(caddy version)"
  printf '  %-20s %s\n' "domain" "$CODE_SERVER_DOMAIN"
  printf '  %-20s %s\n' "bind address" "$CODE_SERVER_BIND_ADDR"
  printf '  %-20s %s\n' "auth user" "$CODE_SERVER_AUTH_USER"
  printf '  %-20s %s\n' "proxy uri" "$CODE_SERVER_PORT_PROXY_URI"

  sudo systemctl --no-pager --lines=0 status "$CODE_SERVER_SERVICE"
  sudo systemctl --no-pager --lines=0 status caddy
}

remove_extension_files() {
  local extension="$1"

  rm -rf "$EXTENSIONS_DIR/$extension"
  rm -rf "$EXTENSIONS_DIR/$extension"-*
}

uninstall_extensions() {
  local extension installed

  [ -n "$EXTENSIONS_INSTALLED_BY_SCRIPT" ] || {
    log "Skipping extension uninstall (nothing tracked)"
    return 0
  }

  installed="$(code-server --list-extensions 2>/dev/null || true)"
  for extension in $EXTENSIONS_INSTALLED_BY_SCRIPT; do
    if printf '%s\n' "$installed" | grep -Fxq "$extension"; then
      log "Removing extension: $extension"
      code-server --uninstall-extension "$extension" || true
    else
      log "Skipping extension $extension (already absent from code-server registry)"
    fi

    if [ -d "$EXTENSIONS_DIR/$extension" ] || compgen -G "$EXTENSIONS_DIR/${extension}-*" >/dev/null; then
      log "Removing extension files: $extension"
      remove_extension_files "$extension"
    fi
  done

  cleanup_empty_dir "$EXTENSIONS_DIR"
}

uninstall_code_server() {
  if [ "$CODE_SERVER_KEEP_PACKAGE" = "1" ]; then
    log "Skipping code-server package uninstall (CODE_SERVER_KEEP_PACKAGE=1)"
    return 0
  fi

  if ! have_cmd code-server && ! sudo test -e "$CODE_SERVER_BIN"; then
    log "Skipping code-server package uninstall (already absent)"
    return 0
  fi

  case "$PKG_MANAGER" in
    apt)
      log "Uninstalling code-server package via apt"
      wait_for_apt_locks
      sudo apt-get purge -y code-server || sudo apt-get remove -y code-server
      sudo apt-get autoremove -y
      ;;
    pacman)
      log "Uninstalling code-server package via pacman"
      sudo pacman -Rns --noconfirm code-server || true
      ;;
    dnf)
      log "Uninstalling code-server package via dnf"
      sudo dnf remove -y code-server || true
      ;;
    *)
      die "Unsupported package manager: $PKG_MANAGER"
      ;;
  esac
}

uninstall_caddy_if_tracked() {
  if [ "$CODE_SERVER_KEEP_CADDY" = "1" ]; then
    log "Skipping caddy package uninstall (CODE_SERVER_KEEP_CADDY=1)"
    return 0
  fi

  if [ "${CADDY_INSTALLED_BY_SCRIPT:-0}" != "1" ] && [ "$CADDY_STATE_TRACKED" = "1" ]; then
    log "Skipping caddy package uninstall (not installed by this script)"
    return 0
  fi

  if ! have_cmd caddy; then
    log "Skipping caddy package uninstall (already absent)"
    return 0
  fi

  log "Stopping caddy service"
  sudo systemctl disable --now caddy >/dev/null 2>&1 || true

  case "$PKG_MANAGER" in
    apt)
      log "Uninstalling caddy package via apt"
      wait_for_apt_locks
      sudo apt-get purge -y caddy || sudo apt-get remove -y caddy
      sudo apt-get autoremove -y
      ;;
    pacman)
      log "Uninstalling caddy package via pacman"
      sudo pacman -Rns --noconfirm caddy || true
      ;;
    dnf)
      log "Uninstalling caddy package via dnf"
      sudo dnf remove -y caddy || true
      ;;
    *)
      die "Unsupported package manager: $PKG_MANAGER"
      ;;
  esac
}

cleanup_managed_files() {
  restore_or_remove "$BACKUP_OVERRIDE_FILE" "$SYSTEMD_OVERRIDE_FILE" sudo
  restore_or_remove "$BACKUP_CADDY_SNIPPET_FILE" "$CADDY_SNIPPET_FILE" sudo
  restore_or_remove "$BACKUP_CADDY_MAIN_CONFIG" "$CADDY_MAIN_CONFIG" sudo
  restore_or_remove "$BACKUP_SETTINGS_FILE" "$SETTINGS_FILE" local
  restore_or_remove "$BACKUP_CONFIG_FILE" "$CONFIG_FILE" local

  cleanup_empty_dir "$SETTINGS_DIR"
  cleanup_empty_dir "$CONFIG_DIR"
  sudo_cleanup_empty_dir "$CADDY_SNIPPET_DIR"
}

disable_services() {
  log "Stopping code-server service"
  sudo systemctl disable --now "$CODE_SERVER_SERVICE" >/dev/null 2>&1 || true

  for _ in $(seq 1 20); do
    if ! sudo systemctl is-active --quiet "$CODE_SERVER_SERVICE"; then
      break
    fi
    sleep 0.5
  done

  sudo systemctl daemon-reload
  if have_cmd caddy && sudo test -f "$CADDY_MAIN_CONFIG"; then
    sudo caddy validate --config "$CADDY_MAIN_CONFIG"
    sudo systemctl reload caddy >/dev/null 2>&1 || true
  fi
}

verify_uninstall() {
  local extension

  log "Verifying uninstall"

  for extension in $EXTENSIONS_INSTALLED_BY_SCRIPT; do
    if [ -d "$EXTENSIONS_DIR/$extension" ] || compgen -G "$EXTENSIONS_DIR/${extension}-*" >/dev/null; then
      die "Extension still installed after uninstall: $extension"
    fi
  done

  verify_restored_or_removed "$BACKUP_OVERRIDE_FILE" "$SYSTEMD_OVERRIDE_FILE" sudo
  verify_restored_or_removed "$BACKUP_CADDY_SNIPPET_FILE" "$CADDY_SNIPPET_FILE" sudo
  verify_restored_or_removed "$BACKUP_CADDY_MAIN_CONFIG" "$CADDY_MAIN_CONFIG" sudo
  verify_restored_or_removed "$BACKUP_SETTINGS_FILE" "$SETTINGS_FILE" local
  verify_restored_or_removed "$BACKUP_CONFIG_FILE" "$CONFIG_FILE" local

  if [ "$CODE_SERVER_KEEP_PACKAGE" != "1" ] && { have_cmd code-server || sudo test -e "$CODE_SERVER_BIN"; }; then
    die "code-server still exists after uninstall: $CODE_SERVER_BIN"
  fi

  if [ "$CODE_SERVER_KEEP_CADDY" != "1" ] && { [ "${CADDY_INSTALLED_BY_SCRIPT:-0}" = "1" ] || [ "$CADDY_STATE_TRACKED" != "1" ]; } && have_cmd caddy; then
    die "caddy still exists after uninstall"
  fi

  [ ! -e "$STATE_FILE" ] || die "State file still exists after uninstall: $STATE_FILE"
  cleanup_empty_dir "$STATE_DIR"
}

uninstall_all() {
  [ "$(id -u)" -ne 0 ] || die "Run as a normal user (not root)."

  if [ -f "$STATE_FILE" ]; then
    load_state
  else
    log "No install state found at $STATE_FILE. Falling back to full code-server cleanup."
    EXTENSIONS_INSTALLED_BY_SCRIPT="${EXTENSIONS[*]}"
  fi

  uninstall_extensions
  disable_services
  cleanup_managed_files
  uninstall_code_server
  uninstall_caddy_if_tracked
  rm -f "$STATE_FILE"
  verify_uninstall

  echo
  log "Uninstall complete. Removed everything tracked from the code-server setup."
}

main() {
  case "${1:-install}" in
    ''|install)
      detect_env
      ensure_requirements
      load_state
      install_caddy
      install_code_server
      ensure_password_hash
      write_code_server_config
      write_code_server_settings
      install_extensions
      write_systemd_override
      ensure_caddy_import
      write_caddy_snippet
      ensure_ufw_http_https
      enable_services
      reload_services
      verify_setup

      cat <<EOF

$LOG_PREFIX Done.
$LOG_PREFIX Open https://$CODE_SERVER_DOMAIN
$LOG_PREFIX Forwarded ports will open as https://<port>.$CODE_SERVER_DOMAIN
$LOG_PREFIX Re-run this script any time to re-apply the same code-server settings, extensions, Caddy config, and systemd override.
EOF
      ;;
    install)
      detect_env
      ensure_requirements
      load_state
      install_caddy
      install_code_server
      ensure_password_hash
      write_code_server_config
      write_code_server_settings
      install_extensions
      write_systemd_override
      ensure_caddy_import
      write_caddy_snippet
      ensure_ufw_http_https
      enable_services
      reload_services
      verify_setup

      cat <<EOF

$LOG_PREFIX Done.
$LOG_PREFIX Open https://$CODE_SERVER_DOMAIN
$LOG_PREFIX Forwarded ports will open as https://<port>.$CODE_SERVER_DOMAIN
$LOG_PREFIX Re-run this script any time to re-apply the same code-server settings, extensions, Caddy config, and systemd override.
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
      install_code_server
      ensure_password_hash
      write_code_server_config
      write_code_server_settings
      install_extensions
      write_systemd_override
      ensure_caddy_import
      write_caddy_snippet
      ensure_ufw_http_https
      enable_services
      reload_services
      verify_setup

      cat <<EOF

$LOG_PREFIX Done.
$LOG_PREFIX Open https://$CODE_SERVER_DOMAIN
$LOG_PREFIX Forwarded ports will open as https://<port>.$CODE_SERVER_DOMAIN
$LOG_PREFIX Re-run this script any time to re-apply the same code-server settings, extensions, Caddy config, and systemd override.
EOF
      ;;
  esac
}

main "$@"
