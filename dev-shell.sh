#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[dev-shell-setup]"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TOOLS_NOTE="ripgrep fd fzf zoxide node pi micro tmux gh"
OS_TYPE=""
STATE_DIR="$HOME/.local/state/shell-scripts"
STATE_FILE="$STATE_DIR/dev-shell.env"
NODE_DIST_INDEX_URL="${NODE_DIST_INDEX_URL:-https://nodejs.org/dist/index.json}"
NODE_INSTALL_DIR="$HOME/.local/share/shell-scripts/node"
NODE_BIN_DIR="$NODE_INSTALL_DIR/bin"
MICRO_LSP_DIR="$HOME/.config/micro/plug/lsp"
MICRO_SETTINGS_FILE="$HOME/.config/micro/settings.json"
TMUX_CONF_FILE="$HOME/.tmux.conf"
TMUX_STATUS_METRICS_FILE="$HOME/.local/bin/tmux-status-metrics"
BREW_FORMULAS=(
  ripgrep
  fd
  fzf
  zoxide
  micro
  tmux
  gh
)
APT_PACKAGES=(
  ca-certificates
  curl
  git
  psmisc
  tar
  xz-utils
  ripgrep
  fd-find
  fzf
  zoxide
  micro
  tmux
  gh
)
NPM_PACKAGES=(
  typescript
  typescript-language-server
  @earendil-works/pi-coding-agent
)

SHELL_NAME=""
SHELL_RC_FILE=""
SHELL_PROFILE_FILE=""

BREW_INSTALLED_BY_SCRIPT=0
BREW_FORMULAS_INSTALLED_BY_SCRIPT=""
APT_PACKAGES_INSTALLED_BY_SCRIPT=""
NPM_PACKAGES_INSTALLED_BY_SCRIPT=""
NODE_INSTALLED_BY_SCRIPT=0
BACKUP_BASHRC=""
BACKUP_ZSHRC=""
BACKUP_PROFILE=""
BACKUP_ZPROFILE=""
BACKUP_MICRO_LSP_DIR=""
BACKUP_MICRO_SETTINGS_FILE=""
BACKUP_TMUX_CONF_FILE=""
BACKUP_TMUX_STATUS_METRICS_FILE=""
MANAGED_BASHRC=0
MANAGED_ZSHRC=0
MANAGED_PROFILE=0
MANAGED_ZPROFILE=0
MANAGED_MICRO_LSP_DIR=0
MANAGED_MICRO_SETTINGS_FILE=0
MANAGED_TMUX_CONF_FILE=0
MANAGED_TMUX_STATUS_METRICS_FILE=0
PI_DIR_EXISTED_BEFORE=0
PI_AGENT_DIR_EXISTED_BEFORE=0
PI_STATE_SNAPSHOTTED=0
STATE_HAS_MANAGED_FLAGS=0

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

have_any_cmd() {
  local cmd

  for cmd in "$@"; do
    if have_cmd "$cmd"; then
      return 0
    fi
  done

  return 1
}

need_cmd() {
  have_cmd "$1" || die "Missing required command: $1"
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

run_as_root() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
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
      if run_as_root fuser "$lock_path" >/dev/null 2>&1; then
        locked=1
        break
      fi
    done

    [ "$locked" -eq 0 ] && return 0
    log "Waiting for apt/dpkg lock to clear"
    sleep 3
  done
}

brew_bin_path() {
  if have_cmd brew; then
    command -v brew
    return 0
  fi

  for candidate in \
    /home/linuxbrew/.linuxbrew/bin/brew \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_brew_shellenv() {
  local brew_bin

  brew_bin="$(brew_bin_path)" || die "Homebrew not found after installation"
  eval "$("$brew_bin" shellenv)"
}

ensure_node_path() {
  case ":$PATH:" in
    *":$NODE_BIN_DIR:"*) ;;
    *) PATH="$NODE_BIN_DIR:$PATH" ;;
  esac

  export PATH
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    if grep -q '^MANAGED_' "$STATE_FILE" 2>/dev/null; then
      STATE_HAS_MANAGED_FLAGS=1
    fi

    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

snapshot_pi_state() {
  [ "$PI_STATE_SNAPSHOTTED" = "0" ] || return 0

  [ -e "$HOME/.pi" ] && PI_DIR_EXISTED_BEFORE=1 || PI_DIR_EXISTED_BEFORE=0
  [ -e "$HOME/.pi/agent" ] && PI_AGENT_DIR_EXISTED_BEFORE=1 || PI_AGENT_DIR_EXISTED_BEFORE=0
  PI_STATE_SNAPSHOTTED=1
  save_state
}

migrate_legacy_state() {
  [ "$STATE_HAS_MANAGED_FLAGS" = "0" ] || return 0

  log "Migrating legacy install state for safer uninstall tracking"

  MANAGED_MICRO_LSP_DIR=1
  MANAGED_MICRO_SETTINGS_FILE=1
  MANAGED_TMUX_CONF_FILE=1
  MANAGED_TMUX_STATUS_METRICS_FILE=1

  if [ "$OS_TYPE" = "linux" ]; then
    MANAGED_BASHRC=1
    MANAGED_PROFILE=1
  else
    MANAGED_ZSHRC=1
    MANAGED_ZPROFILE=1
  fi

  # Legacy states did not record whether ~/.pi existed before install, so keep
  # user pi data rather than guessing and deleting sessions/settings.
  PI_DIR_EXISTED_BEFORE=1
  PI_AGENT_DIR_EXISTED_BEFORE=1
  PI_STATE_SNAPSHOTTED=1

  save_state
  STATE_HAS_MANAGED_FLAGS=1
}

save_state() {
  mkdir -p "$STATE_DIR"

  {
    printf 'BREW_INSTALLED_BY_SCRIPT=%q\n' "$BREW_INSTALLED_BY_SCRIPT"
    printf 'BREW_FORMULAS_INSTALLED_BY_SCRIPT=%q\n' "$BREW_FORMULAS_INSTALLED_BY_SCRIPT"
    printf 'APT_PACKAGES_INSTALLED_BY_SCRIPT=%q\n' "$APT_PACKAGES_INSTALLED_BY_SCRIPT"
    printf 'NPM_PACKAGES_INSTALLED_BY_SCRIPT=%q\n' "$NPM_PACKAGES_INSTALLED_BY_SCRIPT"
    printf 'NODE_INSTALLED_BY_SCRIPT=%q\n' "$NODE_INSTALLED_BY_SCRIPT"
    printf 'BACKUP_BASHRC=%q\n' "$BACKUP_BASHRC"
    printf 'BACKUP_ZSHRC=%q\n' "$BACKUP_ZSHRC"
    printf 'BACKUP_PROFILE=%q\n' "$BACKUP_PROFILE"
    printf 'BACKUP_ZPROFILE=%q\n' "$BACKUP_ZPROFILE"
    printf 'BACKUP_MICRO_LSP_DIR=%q\n' "$BACKUP_MICRO_LSP_DIR"
    printf 'BACKUP_MICRO_SETTINGS_FILE=%q\n' "$BACKUP_MICRO_SETTINGS_FILE"
    printf 'BACKUP_TMUX_CONF_FILE=%q\n' "$BACKUP_TMUX_CONF_FILE"
    printf 'BACKUP_TMUX_STATUS_METRICS_FILE=%q\n' "$BACKUP_TMUX_STATUS_METRICS_FILE"
    printf 'MANAGED_BASHRC=%q\n' "$MANAGED_BASHRC"
    printf 'MANAGED_ZSHRC=%q\n' "$MANAGED_ZSHRC"
    printf 'MANAGED_PROFILE=%q\n' "$MANAGED_PROFILE"
    printf 'MANAGED_ZPROFILE=%q\n' "$MANAGED_ZPROFILE"
    printf 'MANAGED_MICRO_LSP_DIR=%q\n' "$MANAGED_MICRO_LSP_DIR"
    printf 'MANAGED_MICRO_SETTINGS_FILE=%q\n' "$MANAGED_MICRO_SETTINGS_FILE"
    printf 'MANAGED_TMUX_CONF_FILE=%q\n' "$MANAGED_TMUX_CONF_FILE"
    printf 'MANAGED_TMUX_STATUS_METRICS_FILE=%q\n' "$MANAGED_TMUX_STATUS_METRICS_FILE"
    printf 'PI_DIR_EXISTED_BEFORE=%q\n' "$PI_DIR_EXISTED_BEFORE"
    printf 'PI_AGENT_DIR_EXISTED_BEFORE=%q\n' "$PI_AGENT_DIR_EXISTED_BEFORE"
    printf 'PI_STATE_SNAPSHOTTED=%q\n' "$PI_STATE_SNAPSHOTTED"
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

track_formula_install() {
  BREW_FORMULAS_INSTALLED_BY_SCRIPT="$(append_unique_word "$1" "$BREW_FORMULAS_INSTALLED_BY_SCRIPT")"
  save_state
}

track_apt_install() {
  APT_PACKAGES_INSTALLED_BY_SCRIPT="$(append_unique_word "$1" "$APT_PACKAGES_INSTALLED_BY_SCRIPT")"
  save_state
}

track_npm_install() {
  NPM_PACKAGES_INSTALLED_BY_SCRIPT="$(append_unique_word "$1" "$NPM_PACKAGES_INSTALLED_BY_SCRIPT")"
  save_state
}

backup_path_if_exists() {
  local var_name="$1"
  local path="$2"
  local current backup

  eval "current=\${$var_name:-}"
  if [ -n "$current" ] && [ -e "$current" ]; then
    log "Skipping backup for $path (already tracked)"
    return 0
  fi

  if [ ! -e "$path" ]; then
    log "Skipping backup for $path (not present)"
    return 0
  fi

  backup="${path}.bak-${TIMESTAMP}"
  cp -R "$path" "$backup"
  eval "$var_name=\$backup"
  log "Backed up $path -> $backup"
  save_state
}

restore_or_remove() {
  local backup="$1"
  local target="$2"
  local managed="${3:-1}"

  if [ -n "$backup" ] && [ -e "$backup" ]; then
    rm -rf "$target"
    mv "$backup" "$target"
    log "Restored $target"
    return 0
  fi

  if [ "$managed" != "1" ]; then
    log "Skipping cleanup for $target (not tracked as managed)"
    return 0
  fi

  if [ -e "$target" ]; then
    rm -rf "$target"
    log "Removed $target"
  else
    log "Skipping cleanup for $target (not present)"
  fi
}

cleanup_empty_dir() {
  local dir="$1"

  if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    rmdir "$dir"
  fi
}

detect_os() {
  case "$(uname -s)" in
    Linux) OS_TYPE="linux" ;;
    Darwin) OS_TYPE="macos" ;;
    *) die "Unsupported OS. This script supports Linux and macOS only." ;;
  esac
}

validate_privilege_mode() {
  if is_root && [ "$OS_TYPE" = "macos" ]; then
    die "Root mode is supported on Linux only; run as a normal user on macOS."
  fi
}

resolve_shell_files() {
  case "$OS_TYPE" in
    macos)
      SHELL_NAME="zsh"
      SHELL_RC_FILE="$HOME/.zshrc"
      SHELL_PROFILE_FILE="$HOME/.zprofile"
      ;;
    linux)
      SHELL_NAME="bash"
      SHELL_RC_FILE="$HOME/.bashrc"
      SHELL_PROFILE_FILE="$HOME/.profile"
      ;;
    *)
      die "Unsupported OS for shell setup: $OS_TYPE"
      ;;
  esac
}

ensure_homebrew() {
  [ "$OS_TYPE" = "macos" ] || return 0

  if have_cmd brew || brew_bin_path >/dev/null 2>&1; then
    log "Skipping Homebrew install (already available)"
    ensure_brew_shellenv
    return 0
  fi

  need_cmd curl
  log "Installing Homebrew for $OS_TYPE"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW_INSTALLED_BY_SCRIPT=1
  save_state
  ensure_brew_shellenv
}

apt_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

install_apt_packages() {
  local pkg missing=()

  [ "$OS_TYPE" = "linux" ] || return 0

  is_root || need_cmd sudo
  need_cmd apt-get

  for pkg in "${APT_PACKAGES[@]}"; do
    if ! apt_package_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    log "Skipping apt package phase (all packages already installed)"
    return 0
  fi

  log "Ensuring packages"
  wait_for_apt_locks
  run_as_root apt-get update
  wait_for_apt_locks
  run_as_root apt-get install -y "${missing[@]}"

  for pkg in "${missing[@]}"; do
    track_apt_install "$pkg"
  done
}

install_formula_if_missing() {
  local formula="$1"

  if brew list --versions "$formula" >/dev/null 2>&1; then
    log "Skipping brew formula $formula (already installed)"
    return 0
  fi

  log "Installing brew formula: $formula"
  brew install "$formula"
  track_formula_install "$formula"
}

node_platform() {
  case "$(uname -s)" in
    Linux) printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    *) return 1 ;;
  esac
}

node_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x64' ;;
    arm64|aarch64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

latest_node_lts_version() {
  local version

  version="$(curl -fsSL "$NODE_DIST_INDEX_URL" | sed -n 's/.*"version":"\(v[0-9][^"]*\)".*"lts":\("[^"]*"\|true\).*/\1/p' | head -n 1)"
  [ -n "$version" ] || die "Unable to determine latest Node.js LTS version"
  printf '%s\n' "$version"
}

ensure_node_runtime() {
  local platform arch node_version installed_version archive_name archive_url tmp_dir extracted_dir

  platform="$(node_platform)" || die "Unsupported OS for Node.js runtime install"
  arch="$(node_arch)" || die "Unsupported architecture for Node.js runtime install"

  need_cmd curl
  need_cmd tar

  node_version="$(latest_node_lts_version)"

  if [ -x "$NODE_BIN_DIR/node" ] && [ -x "$NODE_BIN_DIR/npm" ]; then
    installed_version="$($NODE_BIN_DIR/node -v)"
    if [ "$installed_version" = "$node_version" ]; then
      ensure_node_path
      return 0
    fi
  fi

  tmp_dir="$(mktemp -d)"
  archive_name="node-${node_version}-${platform}-${arch}.tar.xz"
  archive_url="https://nodejs.org/dist/${node_version}/${archive_name}"

  log "Installing Node.js LTS $node_version"
  curl -fsSL "$archive_url" -o "$tmp_dir/$archive_name"
  tar -xJf "$tmp_dir/$archive_name" -C "$tmp_dir"

  extracted_dir="$tmp_dir/node-${node_version}-${platform}-${arch}"
  [ -d "$extracted_dir" ] || die "Extracted Node.js directory not found"

  rm -rf "$NODE_INSTALL_DIR"
  mkdir -p "$(dirname "$NODE_INSTALL_DIR")"
  mv "$extracted_dir" "$NODE_INSTALL_DIR"
  rm -rf "$tmp_dir"

  NODE_INSTALLED_BY_SCRIPT=1
  save_state
  ensure_node_path
}

all_brew_formulas_installed() {
  local formula

  for formula in "${BREW_FORMULAS[@]}"; do
    if ! brew list --versions "$formula" >/dev/null 2>&1; then
      return 1
    fi
  done

  return 0
}

install_brew_formulas() {
  local formula

  [ "$OS_TYPE" = "macos" ] || return 0

  need_cmd brew

  if all_brew_formulas_installed; then
    log "Skipping brew formula phase (all formulas already installed)"
    return 0
  fi

  log "Ensuring formulas"
  brew update

  for formula in "${BREW_FORMULAS[@]}"; do
    install_formula_if_missing "$formula"
  done
}

npm_global_package_missing() {
  local pkg="$1"

  ! npm list -g --depth=0 "$pkg" >/dev/null 2>&1
}

npm_global_install_if_missing() {
  local pkg="$1"

  if ! npm_global_package_missing "$pkg"; then
    log "Skipping npm package $pkg (already installed globally)"
    return 0
  fi

  log "Installing npm package globally: $pkg"
  npm install -g "$pkg"
  track_npm_install "$pkg"
}

all_npm_packages_installed() {
  local pkg

  for pkg in "${NPM_PACKAGES[@]}"; do
    if npm_global_package_missing "$pkg"; then
      return 1
    fi
  done

  return 0
}

npm_global_bin_dir() {
  local npm_prefix npm_bin

  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  [ -n "$npm_prefix" ] || return 0

  npm_bin="$npm_prefix/bin"
  if [ -d "$npm_bin" ]; then
    printf '%s\n' "$npm_bin"
  fi
}

bashrc_is_managed() {
  [ -f "$SHELL_RC_FILE" ] && grep -q '^# managed by dev-shell$' "$SHELL_RC_FILE" 2>/dev/null
}

write_bashrc() {
  [ "$SHELL_NAME" = "bash" ] || return 0

  if bashrc_is_managed; then
    log "Skipping $SHELL_RC_FILE rewrite (already managed)"
    return 0
  fi

  backup_path_if_exists BACKUP_BASHRC "$SHELL_RC_FILE"

  MANAGED_BASHRC=1
  save_state

  cat > "$SHELL_RC_FILE" <<'EOF'
# managed by dev-shell
# ~/.bashrc

# --- PATH setup ---
path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}

path_prepend "$HOME/.local/bin"
path_prepend "$HOME/.local/share/shell-scripts/node/bin"
path_prepend "$HOME/.pi/bin"

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# --- Aliases ---
if command -v rg >/dev/null 2>&1; then
  alias grep='rg'
fi

if command -v fd >/dev/null 2>&1; then
  alias find='fd'
elif command -v fdfind >/dev/null 2>&1; then
  alias find='fdfind'
fi

if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
  alias cd='z'
fi

alias reload='source ~/.bashrc'
alias dev='tmux new-session -A -s dev'
alias gs='git status -sb'
alias gd='git diff'
alias usage='$HOME/.local/bin/tmux-status-metrics'

__ps1_git_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null
}

__prompt() {
  local exit_code=$?
  local branch
  branch="$(__ps1_git_branch)"
  local arrow_color='\[\e[1;38;2;200;168;75m\]'
  [ "$exit_code" -ne 0 ] && arrow_color='\[\e[1;31m\]'

  PS1="\[\e[1;38;2;200;168;75m\]\W\[\e[0m\]"
  [ -n "$branch" ] && PS1+=" \[\e[1;90m\]·\[\e[0m\] \[\e[1;38;2;200;168;75m\]${branch}\[\e[0m\]"
  PS1+=" ${arrow_color}❯\[\e[0m\] "
}

PROMPT_COMMAND=__prompt

# --- Functions ---
push() {
  git add . || return 1

  if git diff --cached --quiet; then
    echo "No staged changes to commit"
    return 0
  fi

  git commit -m "chore: update $(date '+%Y-%m-%d %H:%M')" && git push
}

mf() {
  local query="${1:-}"
  local selected=""
  local fd_cmd=""

  if ! command -v micro >/dev/null 2>&1; then
    echo "micro is not installed"
    return 1
  fi

  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf is not installed"
    return 1
  fi

  if command -v fd >/dev/null 2>&1; then
    fd_cmd="fd"
  elif command -v fdfind >/dev/null 2>&1; then
    fd_cmd="fdfind"
  else
    echo "fd is not installed"
    return 1
  fi

  selected="$(
    "$fd_cmd" \
      --type f \
      --hidden \
      --follow \
      --exclude .git \
      --exclude node_modules \
      --exclude .next \
      --exclude dist \
      --exclude build \
      --exclude coverage \
      --exclude .cache \
      --exclude .venv \
      --exclude venv \
      . | \
      fzf \
        --query "$query" \
        --select-1 \
        --exit-0 \
        --layout=reverse \
        --height=40%
  )"

  [ -n "$selected" ] || return 0
  micro "$selected"
}

EOF

  log "Written ~/.bashrc"
}

zshrc_is_managed() {
  [ -f "$SHELL_RC_FILE" ] && grep -q '^# managed by dev-shell$' "$SHELL_RC_FILE" 2>/dev/null
}

write_zshrc() {
  [ "$SHELL_NAME" = "zsh" ] || return 0

  if zshrc_is_managed; then
    log "Skipping $SHELL_RC_FILE rewrite (already managed)"
    return 0
  fi

  backup_path_if_exists BACKUP_ZSHRC "$SHELL_RC_FILE"

  MANAGED_ZSHRC=1
  save_state

  cat > "$SHELL_RC_FILE" <<'EOF'
# managed by dev-shell
# ~/.zshrc

# --- PATH setup ---
path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1:$PATH" ;;
  esac
}

path_prepend "$HOME/.local/bin"
path_prepend "$HOME/.local/share/shell-scripts/node/bin"
path_prepend "$HOME/.pi/bin"

# Homebrew (Apple Silicon or Intel)
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# --- Shell options and completion ---
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt hist_ignore_dups hist_ignore_space share_history interactive_comments
autoload -Uz compinit && compinit

# --- Aliases ---
if command -v rg >/dev/null 2>&1; then
  alias grep='rg'
fi

if command -v fd >/dev/null 2>&1; then
  alias find='fd'
fi

if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
  alias cd='z'
fi

alias reload='source ~/.zshrc'
alias dev='tmux new-session -A -s dev'
alias gs='git status -sb'
alias gd='git diff'
alias usage='$HOME/.local/bin/tmux-status-metrics'

# --- Prompt ---
__zsh_git_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null
}

__prompt() {
  local exit_code=$?
  local branch
  branch="$(__zsh_git_branch)"
  local arrow_color='%F{#c8a84b}%B'
  [ "$exit_code" -ne 0 ] && arrow_color='%F{red}%B'

  PROMPT="%F{#c8a84b}%B%1~%b%f"
  [ -n "$branch" ] && PROMPT+=" %F{245}·%f %F{#c8a84b}%B${branch}%b%f"
  PROMPT+=" ${arrow_color}❯%b%f "
}

precmd_functions+=(__prompt)

# --- Functions ---
push() {
  git add . || return 1

  if git diff --cached --quiet; then
    echo "No staged changes to commit"
    return 0
  fi

  git commit -m "chore: update $(date '+%Y-%m-%d %H:%M')" && git push
}

mf() {
  local query="${1:-}"
  local selected=""

  if ! command -v micro >/dev/null 2>&1; then
    echo "micro is not installed"
    return 1
  fi

  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf is not installed"
    return 1
  fi

  if ! command -v fd >/dev/null 2>&1; then
    echo "fd is not installed"
    return 1
  fi

  selected="$(
    fd \
      --type f \
      --hidden \
      --follow \
      --exclude .git \
      --exclude node_modules \
      --exclude .next \
      --exclude dist \
      --exclude build \
      --exclude coverage \
      --exclude .cache \
      --exclude .venv \
      --exclude venv \
      . | \
      fzf \
        --query "$query" \
        --select-1 \
        --exit-0 \
        --layout=reverse \
        --height=40%
  )"

  [ -n "$selected" ] || return 0
  micro "$selected"
}

EOF

  log "Written ~/.zshrc"
}

profile_is_managed() {
  [ -f "$SHELL_PROFILE_FILE" ] && grep -q '^# managed by dev-shell$' "$SHELL_PROFILE_FILE" 2>/dev/null
}

write_profile() {
  local npm_bin

  [ "$SHELL_NAME" = "bash" ] || return 0

  if profile_is_managed; then
    log "Skipping $SHELL_PROFILE_FILE rewrite (already managed)"
    return 0
  fi

  backup_path_if_exists BACKUP_PROFILE "$SHELL_PROFILE_FILE"
  npm_bin="$(npm_global_bin_dir)"

  MANAGED_PROFILE=1
  save_state

  cat > "$SHELL_PROFILE_FILE" <<EOF
# managed by dev-shell
# ~/.profile: executed by the command interpreter for login shells.

# if running bash
if [ -n "\$BASH_VERSION" ]; then
    if [ -f "\$HOME/.bashrc" ]; then
        . "\$HOME/.bashrc"
    fi
fi

if [ -d "\$HOME/bin" ] ; then
    PATH="\$HOME/bin:\$PATH"
fi

if [ -d "\$HOME/.local/bin" ] ; then
    PATH="\$HOME/.local/bin:\$PATH"
fi

if [ -d "\$HOME/.local/share/shell-scripts/node/bin" ] ; then
    PATH="\$HOME/.local/share/shell-scripts/node/bin:\$PATH"
fi

if [ -d "\$HOME/.pi/bin" ] ; then
    PATH="\$HOME/.pi/bin:\$PATH"
fi
EOF

  if [ -n "$npm_bin" ]; then
    cat >> "$SHELL_PROFILE_FILE" <<EOF

if [ -d "$npm_bin" ] ; then
    PATH="$npm_bin:\$PATH"
fi
EOF
  fi

  log "Written ~/.profile"
}

zprofile_is_managed() {
  [ -f "$SHELL_PROFILE_FILE" ] && grep -q '^# managed by dev-shell$' "$SHELL_PROFILE_FILE" 2>/dev/null
}

write_zprofile() {
  local npm_bin

  [ "$SHELL_NAME" = "zsh" ] || return 0

  if zprofile_is_managed; then
    log "Skipping $SHELL_PROFILE_FILE rewrite (already managed)"
    return 0
  fi

  backup_path_if_exists BACKUP_ZPROFILE "$SHELL_PROFILE_FILE"
  npm_bin="$(npm_global_bin_dir)"

  MANAGED_ZPROFILE=1
  save_state

  cat > "$SHELL_PROFILE_FILE" <<EOF
# managed by dev-shell
# ~/.zprofile: sourced by zsh for login shells.

# Homebrew (Apple Silicon or Intel)
if [ -x /opt/homebrew/bin/brew ]; then
  eval "\$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "\$(/usr/local/bin/brew shellenv)"
fi

path_prepend() {
  case ":\$PATH:" in
    *":\$1:"*) ;;
    *) PATH="\$1:\$PATH" ;;
  esac
}

path_prepend "\$HOME/.local/bin"
path_prepend "\$HOME/.local/share/shell-scripts/node/bin"
path_prepend "\$HOME/.pi/bin"
EOF

  if [ -n "$npm_bin" ]; then
    cat >> "$SHELL_PROFILE_FILE" <<EOF

path_prepend "$npm_bin"
EOF
  fi

  cat >> "$SHELL_PROFILE_FILE" <<'EOF'

export PATH
EOF

  log "Written ~/.zprofile"
}

micro_lsp_is_managed() {
  [ -d "$MICRO_LSP_DIR" ] && [ -f "$MICRO_LSP_DIR/main.lua" ]
}

install_micro_lsp_plugin() {
  need_cmd micro

  if micro_lsp_is_managed; then
    log "Skipping micro lsp install (plugin already present)"
    return 0
  fi

  backup_path_if_exists BACKUP_MICRO_LSP_DIR "$MICRO_LSP_DIR"
  MANAGED_MICRO_LSP_DIR=1
  save_state
  log "Installing micro lsp plugin"

  if micro -plugin install lsp; then
    return 0
  fi

  log "micro plugin command failed, falling back to direct git clone"
  need_cmd git
  mkdir -p "$HOME/.config/micro/plug"

  if [ -d "$MICRO_LSP_DIR/.git" ]; then
    git -C "$MICRO_LSP_DIR" pull --ff-only
  else
    rm -rf "$MICRO_LSP_DIR"
    git clone https://github.com/AndCake/micro-plugin-lsp "$MICRO_LSP_DIR"
  fi
}

patch_micro_lsp_plugin() {
  local plugin_main
  plugin_main="$MICRO_LSP_DIR/main.lua"

  [ -f "$plugin_main" ] || die "micro lsp plugin file not found: $plugin_main"

  if grep -Fq "if data.params and data.params.uri == uri then" "$plugin_main"; then
    log "Skipping micro lsp patch (already applied)"
    return 0
  fi

  node - "$plugin_main" <<'NODE'
const fs = require('fs');

const file = process.argv[2];
const before = [
  '\t\t\tlocal bp = micro.CurPane().Buf',
  '\t\t\tbp:ClearMessages("lsp")',
  '\t\t\tbp:AddMessage(buffer.NewMessage("lsp", "", buffer.Loc(0, 10000000), buffer.Loc(0, 10000000), buffer.MTInfo))',
  '\t\t\tlocal uri = getUriFromBuf(bp)',
  '\t\t\tif data.params.uri == uri then'
].join('\n');

const after = [
  '\t\t\tlocal bp = micro.CurPane().Buf',
  '\t\t\tlocal uri = getUriFromBuf(bp)',
  '\t\t\tif data.params and data.params.uri == uri then',
  '\t\t\t\tbp:ClearMessages("lsp")',
  '\t\t\t\tbp:AddMessage(buffer.NewMessage("lsp", "", buffer.Loc(0, 10000000), buffer.Loc(0, 10000000), buffer.MTInfo))'
].join('\n');

const raw = fs.readFileSync(file, 'utf8');
if (!raw.includes(before)) {
  console.error(`Expected diagnostics block not found in ${file}`);
  process.exit(1);
}

fs.writeFileSync(file, raw.replace(before, after));
NODE

  log "Patched micro lsp plugin diagnostics handling"
}

micro_settings_are_managed() {
  [ -f "$MICRO_SETTINGS_FILE" ] && grep -q '"lsp.server"' "$MICRO_SETTINGS_FILE" 2>/dev/null
}

configure_micro_settings() {
  local settings_dir node_path npm_root tsls_cli tsls_cmd

  if micro_settings_are_managed; then
    log "Skipping micro settings update (already managed)"
    return 0
  fi

  settings_dir="$(dirname "$MICRO_SETTINGS_FILE")"
  mkdir -p "$settings_dir"
  backup_path_if_exists BACKUP_MICRO_SETTINGS_FILE "$MICRO_SETTINGS_FILE"

  if [ ! -f "$MICRO_SETTINGS_FILE" ]; then
    printf '{}\n' > "$MICRO_SETTINGS_FILE"
  fi
  MANAGED_MICRO_SETTINGS_FILE=1
  save_state

  node_path="$(command -v node || true)"
  npm_root="$(npm root -g 2>/dev/null || true)"
  tsls_cli="${npm_root:+$npm_root/typescript-language-server/lib/cli.mjs}"

  if [ -n "$node_path" ] && [ -n "$tsls_cli" ] && [ -f "$tsls_cli" ]; then
    tsls_cmd="$node_path $tsls_cli --stdio"
  else
    tsls_cmd="typescript-language-server --stdio"
  fi

  TSLS_CMD="$tsls_cmd" node - "$MICRO_SETTINGS_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const tslsCmd = process.env.TSLS_CMD || 'typescript-language-server --stdio';

let data = {};
try {
  const raw = fs.readFileSync(file, 'utf8').trim();
  data = raw ? JSON.parse(raw) : {};
} catch (err) {
  console.error(`Failed to parse ${file}: ${err.message}`);
  process.exit(1);
}

data["lsp.server"] = `typescript=${tslsCmd},typescriptreact=${tslsCmd},tsx=${tslsCmd},javascript=${tslsCmd},javascriptreact=${tslsCmd},jsx=${tslsCmd}`;
data["lsp.tabcompletion"] = true;
data["lsp.formatOnSave"] = false;
data["lsp.autocompleteDetails"] = false;
data["softwrap"] = true;
data["wordwrap"] = true;

fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
NODE

  log "Updated $MICRO_SETTINGS_FILE"
}

tmux_status_metrics_are_managed() {
  [ -f "$TMUX_STATUS_METRICS_FILE" ] && grep -q '^# managed by dev-shell$' "$TMUX_STATUS_METRICS_FILE" 2>/dev/null
}

write_tmux_status_metrics() {
  local bin_dir

  if tmux_status_metrics_are_managed; then
    log "Skipping tmux metrics helper rewrite (already managed)"
    return 0
  fi

  bin_dir="$(dirname "$TMUX_STATUS_METRICS_FILE")"
  backup_path_if_exists BACKUP_TMUX_STATUS_METRICS_FILE "$TMUX_STATUS_METRICS_FILE"
  mkdir -p "$bin_dir"
  MANAGED_TMUX_STATUS_METRICS_FILE=1
  save_state

  cat > "$TMUX_STATUS_METRICS_FILE" <<'EOF'
#!/bin/sh
# managed by dev-shell

set -eu

os_type="$(uname -s)"

if [ "$os_type" = "Darwin" ]; then
  # macOS: CPU via top, RAM via vm_stat + sysctl
  cpu_pct="$(top -l 1 -s 0 | awk '/^CPU usage:/ { gsub(/%.*/, "", $3); printf "%.1f", $3 }')"

  page_size="$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)"
  vm_stat_out="$(vm_stat 2>/dev/null)"
  pages_free="$(printf '%s\n' "$vm_stat_out"     | awk '/Pages free:/      { gsub(/\./, "", $3); print $3 }')"
  pages_inactive="$(printf '%s\n' "$vm_stat_out" | awk '/Pages inactive:/  { gsub(/\./, "", $3); print $3 }')"
  mem_total_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"

  mem_total="$(( mem_total_bytes / 1024 / 1024 ))"
  mem_free="$(( (pages_free + pages_inactive) * page_size / 1024 / 1024 ))"
  mem_used="$(( mem_total - mem_free ))"

  [ -n "$cpu_pct" ] || cpu_pct="n/a"
  printf 'CPU %s%% RAM %s/%sMB\n' "$cpu_pct" "$mem_used" "$mem_total"
else
  # Linux: CPU via /proc/stat, RAM via /proc/meminfo
  if [ ! -r /proc/stat ] || [ ! -r /proc/meminfo ]; then
    printf 'CPU n/a RAM n/a\n'
    exit 0
  fi

  # Get snapshots and calculate usage using awk
  cpu_pct=$(awk '
    /^cpu / {
      idle = $5 + $6
      total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
      print idle " " total
    }
  ' /proc/stat)
  
  sleep 0.2
  
  cpu_pct=$(awk -v prev="$cpu_pct" '
    /^cpu / {
      split(prev, p)
      idle = $5 + $6
      total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
      
      diff_idle = idle - p[1]
      diff_total = total - p[2]
      
      if (diff_total == 0) printf "0.0"
      else printf "%.1f", 100 * (1 - diff_idle / diff_total)
    }
  ' /proc/stat)

  mem="$(awk '
    /^MemTotal:/     { total = int($2/1024) }
    /^MemAvailable:/ { avail = int($2/1024) }
    END { printf "%d %d\n", total-avail, total }
  ' /proc/meminfo)"
  mem_used="${mem% *}"
  mem_total="${mem#* }"

  printf 'CPU %s%% RAM %s/%sMB\n' "$cpu_pct" "$mem_used" "$mem_total"
fi
EOF

  chmod +x "$TMUX_STATUS_METRICS_FILE"
  log "Written $TMUX_STATUS_METRICS_FILE"
}

tmux_conf_is_managed() {
  [ -f "$TMUX_CONF_FILE" ] && grep -q '^# managed by dev-shell$' "$TMUX_CONF_FILE" 2>/dev/null
}

write_tmux_conf() {
  local default_shell default_command

  if tmux_conf_is_managed; then
    log "Skipping ~/.tmux.conf rewrite (already managed)"
    return 0
  fi

  backup_path_if_exists BACKUP_TMUX_CONF_FILE "$TMUX_CONF_FILE"

  if [ "$OS_TYPE" = "macos" ]; then
    default_shell="/bin/zsh"
    default_command="/bin/zsh -l"
  else
    default_shell="/bin/bash"
    default_command="/bin/bash -l"
  fi

  MANAGED_TMUX_CONF_FILE=1
  save_state

  cat > "$TMUX_CONF_FILE" <<EOF
# managed by dev-shell
##### Base Config #####

set-environment -g TZ "Europe/Moscow"

set -g default-terminal "tmux-256color"
set -g extended-keys on
set -g default-shell "$default_shell"
set -g default-command "$default_command"
set -ga terminal-features ",xterm-256color:RGB,focus,clipboard"
set -ga terminal-features ",xterm-ghostty:RGB,focus,clipboard"
set -g set-clipboard on
set -g allow-passthrough on
set -g focus-events on
set -g mouse on
set -sg escape-time 0
set -g history-limit 10000
setw -g mode-keys vi

##### Splits #####

# Default tmux:
#   prefix + "   -> horizontal split
#   prefix + %   -> vertical split
#
# Extra ergonomics:
bind - split-window -v
bind | split-window -h

##### Mouse #####

bind -n MouseDown1Pane select-pane -t = \; send-keys -M

##### Vim-style pane navigation (no prefix) #####

bind -n C-h select-pane -L
bind -n C-j select-pane -D
bind -n C-k select-pane -U
bind -n C-l select-pane -R

##### Resize panes quickly with Alt + h/j/k/l #####

bind -n M-h resize-pane -L 5
bind -n M-j resize-pane -D 5
bind -n M-k resize-pane -U 5
bind -n M-l resize-pane -R 5

##### Pane borders #####

set -g pane-border-style "fg=colour240"
set -g pane-active-border-style "fg=colour240"
set -g pane-border-lines heavy

##### Status bar #####

set -g status-position bottom
set -g status-style "bg=#222222,fg=#b8a060"
set -g status-justify right
set -g status-left-length 60
set -g status-right-length 160
set -g base-index 1
setw -g pane-base-index 1
set -g status-interval 15

set -g status-left "#[bg=#c8a84b,fg=#222222,bold]  #{b:pane_current_path} #[bg=#222222,fg=#c8a84b,nobold]"
set -g status-right "#[bg=#c8a84b,fg=#222222] %a %d %b #[bold]%H:%M %Z "

setw -g window-status-format "#[fg=#7a6a3a]  #W  "
setw -g window-status-current-format "#[bg=#2e2e2e,fg=#c8a84b,bold]  #W  #[default]"
setw -g window-status-separator ""

set -g message-style "bg=#2e2e2e,fg=#c8a84b,bold"
set -g message-command-style "bg=#222222,fg=#b8a060"
EOF

  log "Written $TMUX_CONF_FILE"
}

verify_install() {
  local missing=0
  local cmd
  local node_path npm_path
  log "Verification"
  for cmd in rg fzf zoxide micro tmux gh typescript-language-server tsc; do
    if have_cmd "$cmd"; then
      printf '  %-26s %s\n' "$cmd" "$(command -v "$cmd")"
    else
      printf '  %-26s %s\n' "$cmd" "NOT FOUND"
      missing=1
    fi
  done

  if [ "$OS_TYPE" = "macos" ]; then
    if have_cmd brew; then
      printf '  %-26s %s\n' "brew" "$(command -v brew)"
    else
      printf '  %-26s %s\n' "brew" "NOT FOUND"
      missing=1
    fi

    if have_cmd zsh; then
      printf '  %-26s %s\n' "zsh" "$(command -v zsh)"
    else
      printf '  %-26s %s\n' "zsh" "NOT FOUND"
      missing=1
    fi
  fi

  if have_cmd fd; then
    printf '  %-26s %s\n' "fd" "$(command -v fd)"
  elif have_cmd fdfind; then
    printf '  %-26s %s\n' "fd" "$(command -v fdfind)"
  else
    printf '  %-26s %s\n' "fd" "NOT FOUND"
    missing=1
  fi

  node_path="$NODE_BIN_DIR/node"
  npm_path="$NODE_BIN_DIR/npm"
  if [ -x "$node_path" ]; then
    printf '  %-26s %s\n' "node" "$node_path"
  else
    printf '  %-26s %s\n' "node" "NOT FOUND"
    missing=1
  fi

  if [ -x "$npm_path" ]; then
    printf '  %-26s %s\n' "npm" "$npm_path"
  else
    printf '  %-26s %s\n' "npm" "NOT FOUND"
    missing=1
  fi

  if have_cmd pi; then
    printf '  %-26s %s\n' "pi" "$(command -v pi)"
  else
    printf '  %-26s %s\n' "pi" "NOT FOUND"
    missing=1
  fi

  [ "$missing" -eq 0 ] || die "One or more required commands are missing"
}

write_shell_rc() {
  case "$SHELL_NAME" in
    zsh) write_zshrc ;;
    bash) write_bashrc ;;
    *) die "Unsupported shell for rc file: $SHELL_NAME" ;;
  esac
}

write_shell_profile() {
  case "$SHELL_NAME" in
    zsh) write_zprofile ;;
    bash) write_profile ;;
    *) die "Unsupported shell for profile file: $SHELL_NAME" ;;
  esac
}

install_all() {
  local pkg

  detect_os
  validate_privilege_mode
  resolve_shell_files
  load_state
  ensure_homebrew
  install_apt_packages
  install_brew_formulas
  ensure_node_runtime
  need_cmd node
  need_cmd npm
  snapshot_pi_state

  if all_npm_packages_installed; then
    log "Skipping npm global phase (all packages already installed)"
  else
    for pkg in "${NPM_PACKAGES[@]}"; do
      npm_global_install_if_missing "$pkg"
    done
  fi

  write_shell_rc
  write_shell_profile
  install_micro_lsp_plugin
  patch_micro_lsp_plugin
  configure_micro_settings
  write_tmux_status_metrics
  write_tmux_conf
  verify_install

  echo
  log "Done. Run: source $SHELL_RC_FILE"
}

uninstall_npm_packages() {
  local pkg

  ensure_node_path

  [ -n "$NPM_PACKAGES_INSTALLED_BY_SCRIPT" ] || {
    log "Skipping npm uninstall (nothing tracked)"
    return 0
  }

  if ! have_cmd npm; then
    log "Skipping npm uninstall (npm already absent)"
    return 0
  fi

  for pkg in $NPM_PACKAGES_INSTALLED_BY_SCRIPT; do
    if npm list -g --depth=0 "$pkg" >/dev/null 2>&1; then
      log "Removing npm package: $pkg"
      npm uninstall -g "$pkg"
    else
      log "Skipping npm package $pkg (already absent)"
    fi
  done
}

uninstall_brew_formulas() {
  local formula

  [ "$OS_TYPE" = "macos" ] || return 0

  [ -n "$BREW_FORMULAS_INSTALLED_BY_SCRIPT" ] || {
    log "Skipping brew uninstall (no tracked formulas)"
    return 0
  }

  ensure_brew_shellenv
  for formula in $BREW_FORMULAS_INSTALLED_BY_SCRIPT; do
    if brew list --versions "$formula" >/dev/null 2>&1; then
      log "Removing brew formula: $formula"
      brew uninstall "$formula"
    else
      log "Skipping brew formula $formula (already absent)"
    fi
  done

  log "Cleaning Homebrew unused dependencies and cache"
  brew autoremove || true
  brew cleanup --prune=all || true
}

uninstall_apt_packages() {
  local pkg

  [ "$OS_TYPE" = "linux" ] || return 0

  [ -n "$APT_PACKAGES_INSTALLED_BY_SCRIPT" ] || {
    log "Skipping apt uninstall (no tracked packages)"
    return 0
  }

  is_root || need_cmd sudo
  need_cmd apt-get
  for pkg in $APT_PACKAGES_INSTALLED_BY_SCRIPT; do
    if apt_package_installed "$pkg"; then
      log "Removing apt package: $pkg"
      wait_for_apt_locks
      run_as_root apt-get remove -y "$pkg"
    else
      log "Skipping apt package $pkg (already absent)"
    fi
  done

  log "Cleaning apt unused dependencies and package cache"
  wait_for_apt_locks
  run_as_root apt-get autoremove --purge -y
  run_as_root apt-get clean
}

uninstall_homebrew_if_tracked() {
  [ "$OS_TYPE" = "macos" ] || return 0

  if [ "$BREW_INSTALLED_BY_SCRIPT" != "1" ]; then
    log "Skipping Homebrew uninstall (not installed by this script)"
    return 0
  fi

  need_cmd curl
  log "Removing Homebrew installed by this script"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"
}

cleanup_pi_files_if_tracked() {
  local pi_agent_dir="$HOME/.pi/agent"
  local pi_bin_dir="$HOME/.pi/bin"

  case " $NPM_PACKAGES_INSTALLED_BY_SCRIPT " in
    *" @earendil-works/pi-coding-agent "*) ;;
    *)
      log "Skipping pi file cleanup (pi package was not installed by this script)"
      return 0
      ;;
  esac

  if [ "$PI_AGENT_DIR_EXISTED_BEFORE" = "0" ] && [ -d "$pi_agent_dir" ]; then
    rm -rf "$pi_agent_dir"
    log "Removed $pi_agent_dir"
  else
    log "Skipping $pi_agent_dir cleanup (pre-existing or absent)"
  fi

  cleanup_empty_dir "$pi_bin_dir"

  if [ "$PI_DIR_EXISTED_BEFORE" = "0" ]; then
    cleanup_empty_dir "$HOME/.pi"
  fi
}

verify_pi_files_removed_if_tracked() {
  case " $NPM_PACKAGES_INSTALLED_BY_SCRIPT " in
    *" @earendil-works/pi-coding-agent "*) ;;
    *) return 0 ;;
  esac

  if [ "$PI_AGENT_DIR_EXISTED_BEFORE" = "0" ] && [ -e "$HOME/.pi/agent" ]; then
    die "pi agent directory still exists after uninstall: $HOME/.pi/agent"
  fi

  if [ "$PI_DIR_EXISTED_BEFORE" = "0" ] && [ -d "$HOME/.pi" ] && [ -z "$(ls -A "$HOME/.pi" 2>/dev/null)" ]; then
    die "empty pi directory still exists after uninstall: $HOME/.pi"
  fi
}

uninstall_node_if_tracked() {
  if [ "$NODE_INSTALLED_BY_SCRIPT" != "1" ]; then
    log "Skipping Node.js uninstall (not installed by this script)"
    return 0
  fi

  if [ -d "$NODE_INSTALL_DIR" ]; then
    rm -rf "$NODE_INSTALL_DIR"
    log "Removed $NODE_INSTALL_DIR"
  else
    log "Skipping Node.js uninstall (runtime already absent)"
  fi

  cleanup_empty_dir "$(dirname "$NODE_INSTALL_DIR")"
}

cleanup_managed_files() {
  restore_or_remove "$BACKUP_TMUX_CONF_FILE" "$TMUX_CONF_FILE" "$MANAGED_TMUX_CONF_FILE"
  restore_or_remove "$BACKUP_TMUX_STATUS_METRICS_FILE" "$TMUX_STATUS_METRICS_FILE" "$MANAGED_TMUX_STATUS_METRICS_FILE"
  restore_or_remove "$BACKUP_MICRO_SETTINGS_FILE" "$MICRO_SETTINGS_FILE" "$MANAGED_MICRO_SETTINGS_FILE"
  restore_or_remove "$BACKUP_MICRO_LSP_DIR" "$MICRO_LSP_DIR" "$MANAGED_MICRO_LSP_DIR"
  restore_or_remove "$BACKUP_PROFILE" "$HOME/.profile" "$MANAGED_PROFILE"
  restore_or_remove "$BACKUP_BASHRC" "$HOME/.bashrc" "$MANAGED_BASHRC"
  restore_or_remove "$BACKUP_ZPROFILE" "$HOME/.zprofile" "$MANAGED_ZPROFILE"
  restore_or_remove "$BACKUP_ZSHRC" "$HOME/.zshrc" "$MANAGED_ZSHRC"

  cleanup_empty_dir "$(dirname "$MICRO_LSP_DIR")"
  cleanup_empty_dir "$(dirname "$MICRO_SETTINGS_FILE")"
  cleanup_empty_dir "$HOME/.config/micro"
  cleanup_empty_dir "$HOME/.config"
  cleanup_empty_dir "$HOME/.npm/_logs"
  cleanup_empty_dir "$HOME/.npm"
  cleanup_empty_dir "$(dirname "$TMUX_STATUS_METRICS_FILE")"
}

verify_restored_or_removed() {
  local backup="$1"
  local target="$2"
  local managed="${3:-1}"

  if [ -n "$backup" ]; then
    [ ! -e "$backup" ] || die "Backup still exists after uninstall: $backup"
    [ -e "$target" ] || die "Expected restored path is missing after uninstall: $target"
    return 0
  fi

  [ "$managed" != "1" ] || [ ! -e "$target" ] || die "Managed path still exists after uninstall: $target"
}

verify_uninstall() {
  local pkg formula

  log "Verifying uninstall"

  ensure_node_path
  if have_cmd npm; then
    for pkg in $NPM_PACKAGES_INSTALLED_BY_SCRIPT; do
      if npm list -g --depth=0 "$pkg" >/dev/null 2>&1; then
        die "npm package still installed after uninstall: $pkg"
      fi
    done
  fi

  if brew_bin_path >/dev/null 2>&1; then
    ensure_brew_shellenv
    for formula in $BREW_FORMULAS_INSTALLED_BY_SCRIPT; do
      if brew list --versions "$formula" >/dev/null 2>&1; then
        die "brew formula still installed after uninstall: $formula"
      fi
    done
  fi

  if [ "$OS_TYPE" = "linux" ]; then
    for pkg in $APT_PACKAGES_INSTALLED_BY_SCRIPT; do
      if apt_package_installed "$pkg"; then
        die "apt package still installed after uninstall: $pkg"
      fi
    done
  fi

  if [ "$OS_TYPE" = "macos" ] && [ "$BREW_INSTALLED_BY_SCRIPT" = "1" ] && brew_bin_path >/dev/null 2>&1; then
    die "Homebrew is still present after uninstall"
  fi

  if [ "$NODE_INSTALLED_BY_SCRIPT" = "1" ] && [ -e "$NODE_INSTALL_DIR" ]; then
    die "Node.js runtime still exists after uninstall: $NODE_INSTALL_DIR"
  fi

  verify_pi_files_removed_if_tracked

  verify_restored_or_removed "$BACKUP_TMUX_CONF_FILE" "$TMUX_CONF_FILE" "$MANAGED_TMUX_CONF_FILE"
  verify_restored_or_removed "$BACKUP_TMUX_STATUS_METRICS_FILE" "$TMUX_STATUS_METRICS_FILE" "$MANAGED_TMUX_STATUS_METRICS_FILE"
  verify_restored_or_removed "$BACKUP_MICRO_SETTINGS_FILE" "$MICRO_SETTINGS_FILE" "$MANAGED_MICRO_SETTINGS_FILE"
  verify_restored_or_removed "$BACKUP_MICRO_LSP_DIR" "$MICRO_LSP_DIR" "$MANAGED_MICRO_LSP_DIR"

  if [ "$OS_TYPE" = "linux" ]; then
    verify_restored_or_removed "$BACKUP_PROFILE" "$HOME/.profile" "$MANAGED_PROFILE"
    verify_restored_or_removed "$BACKUP_BASHRC" "$HOME/.bashrc" "$MANAGED_BASHRC"
  else
    verify_restored_or_removed "$BACKUP_ZPROFILE" "$HOME/.zprofile" "$MANAGED_ZPROFILE"
    verify_restored_or_removed "$BACKUP_ZSHRC" "$HOME/.zshrc" "$MANAGED_ZSHRC"
  fi

  [ ! -e "$STATE_FILE" ] || die "State file still exists after uninstall: $STATE_FILE"
}

uninstall_all() {
  detect_os
  validate_privilege_mode
  resolve_shell_files

  if [ ! -f "$STATE_FILE" ]; then
    die "No install state found at $STATE_FILE. Refusing to guess what to remove."
  fi

  load_state
  migrate_legacy_state
  uninstall_npm_packages

  if [ "$OS_TYPE" = "macos" ] && brew_bin_path >/dev/null 2>&1; then
    uninstall_brew_formulas
    uninstall_homebrew_if_tracked
  elif [ "$OS_TYPE" = "macos" ]; then
    log "Skipping brew cleanup (Homebrew already absent)"
  fi

  uninstall_apt_packages

  cleanup_pi_files_if_tracked
  uninstall_node_if_tracked

  cleanup_managed_files
  rm -f "$STATE_FILE"
  verify_uninstall
  cleanup_empty_dir "$STATE_DIR"
  cleanup_empty_dir "$(dirname "$STATE_DIR")"
  cleanup_empty_dir "$HOME/.local/share/shell-scripts"
  cleanup_empty_dir "$HOME/.local/share"
  cleanup_empty_dir "$HOME/.local"

  echo
  log "Uninstall complete. Removed everything tracked from the dev shell setup."
}

main() {
  case "${1:-install}" in
    install)
      install_all
      ;;
    uninstall)
      uninstall_all
      ;;
    *)
      die "Usage: ./dev-shell.sh [install|uninstall]"
      ;;
  esac
}

main "$@"
