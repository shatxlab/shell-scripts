# Shell Scripts

Provisioning scripts for user tooling and remote services.

## Notes

- Run `dev-shell.sh` as a normal user, or as root on Linux. Root installs are
  scoped to the invoking user's `HOME` (normally `/root`) and use direct
  privileged commands instead of requiring `sudo`. macOS still requires a
  normal user because Homebrew does not support root installation.

## Scripts

| Script | Purpose |
| --- | --- |
| `bootstrap-vps.sh` | Bootstraps a VPS from local root access to key-only user SSH |
| `dev-shell.sh` | Installs shell CLI tools, `micro`, `tmux`, and user config files |
| `code-server.sh` | Installs code-server, extensions, systemd wiring, and Caddy |
| `browser.sh` | Installs a remote browser stack behind Caddy + noVNC |
| `setup-dante.sh` | Installs a Dante SOCKS5 proxy on a VPS |
| `setup-mtproto.sh` | Installs a Telegram MTProto proxy on a VPS |


## `bootstrap-vps.sh`

`bootstrap-vps.sh` runs on your local machine and upgrades a fresh VPS from direct root access to a key-only non-root login.

It:

- generates a local SSH key if needed
- connects to the VPS as `root`, or as `EXISTING_USER` when provided
- creates the target user and appends that key to `authorized_keys` if it is missing
- opens port `2233` while keeping port `22` available during the transition
- retries the initial server connection on `2233` if `22` is no longer reachable
- verifies that the new user can log in with the key on `2233`
- only then disables root login and SSH password auth
- writes an SSH config alias on your machine

### Install

Recommended install command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/bootstrap-vps.sh | env SERVER_IP=1.2.3.4 USERNAME=youruser KEY_NAME=work-server bash
```

Use an existing sudo user instead of creating a new user:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/bootstrap-vps.sh | env SERVER_IP=1.2.3.4 EXISTING_USER=youruser KEY_NAME=work-server bash
```

Parameters:

- `SERVER_IP`: target VPS IP or hostname. Required.
- `USERNAME`: non-root sudo user to create. Required unless `EXISTING_USER` is set.
- `EXISTING_USER`: existing sudo user to use instead of connecting as `root` and creating `USERNAME`.
- `KEY_NAME`: SSH key name and SSH config alias. Default: `${USERNAME}-${SERVER_IP}`.

You may be prompted for the existing root SSH password, or the existing user's SSH credentials and sudo password, during the first connection. On reruns, the script tries SSH on port `22` first and falls back to `2233` if needed. After the script finishes, connect with:

```bash
ssh work-server
```

## `dev-shell.sh`

`dev-shell.sh` sets up the local shell environment, CLI tools, `micro`, and `tmux`.

It:

- installs Homebrew on macOS when needed
- installs CLI tooling with `apt` on Linux and Homebrew on macOS
- installs a user-local Node.js runtime when `node`/`npm` are missing
- installs `pi` (`@earendil-works/pi-coding-agent`) via npm when it is missing
- installs global npm packages for the TypeScript LSP
- writes managed versions of `~/.bashrc`, `~/.profile`, `~/.tmux.conf`, and the tmux status helper
- installs and patches the `micro` LSP plugin
- tracks what it changed in `~/.local/state/shell-scripts/dev-shell.env`

Every install step checks whether the target is already present and skips work when possible.

### Install

Recommended install command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/dev-shell.sh | bash
```

Parameters:

- Node.js: installs the latest LTS release from nodejs.org when `node` and `npm` are missing.

### Uninstall

Recommended uninstall command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/dev-shell.sh | bash -s -- uninstall
```

Uninstall only removes packages and files tracked by the script state file. It also restores the original backed-up versions of managed config files when those backups exist.

## `code-server.sh`

Installs code-server, configures Caddy, and exposes the editor on a public domain.

### Install

Recommended install command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/code-server.sh | env CODE_SERVER_DOMAIN=dev.example.com CODE_SERVER_AUTH_USER=username CODE_SERVER_AUTH_PASSWORD=change-me bash
```

Parameters:

- `CODE_SERVER_DOMAIN`: public hostname for the main code-server site. Required.
- `CODE_SERVER_AUTH_USER`: Caddy basic auth username. Default: current `$USER`.
- `CODE_SERVER_AUTH_PASSWORD`: plaintext Caddy basic auth password.

### Uninstall

Recommended uninstall command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/code-server.sh | bash -s -- uninstall
```

Uninstall removes tracked code-server settings, extensions installed by the script, extension files left on disk, Caddy files, the systemd override, and the code-server package, then validates the teardown. Set `CODE_SERVER_KEEP_PACKAGE=1` to keep the code-server package installed.

## `browser.sh`

Installs a remote browser stack with noVNC and places it behind Caddy basic auth.

`BROWSER_DOMAIN` is the public hostname users open to reach the remote browser service.
`BROWSER_START_URL` is the page opened inside the remote browser session after it starts.

### Install

Recommended install command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/browser.sh | env BROWSER_DOMAIN=browser.example.com BROWSER_AUTH_USER=username BROWSER_AUTH_PASSWORD=change-me bash
```

Parameters:

- `BROWSER_DOMAIN`: public hostname for the browser service. Required.
- `BROWSER_AUTH_USER`: Caddy basic auth username. Default: current `$USER`.
- `BROWSER_AUTH_PASSWORD`: plaintext Caddy basic auth password.
- `BROWSER_MEMORY_MAX`: systemd memory cap for the service. Default: `4G`.
- `BROWSER_START_URL`: page opened in the browser session. Default: `about:blank`.

### Uninstall

Recommended uninstall command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/browser.sh | bash -s -- uninstall
```

Uninstall removes tracked browser service files, launcher files, Caddy files, and the managed browser user when this script created it, then validates the teardown.

## `setup-dante.sh`

Installs and configures a passwordless Dante SOCKS5 proxy on a VPS.

Recommended install command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/setup-dante.sh | sudo bash -s -- 24861 proxy.example.com
```

Parameters:

- First argument: SOCKS5 proxy port. Default: `24861`.
- Second argument: domain to print in the endpoint/test command. Optional. You can also set `SERVER_DOMAIN` or `DOMAIN`.

The script supports Debian/Ubuntu and RHEL-like distributions, opens the port through `ufw` or `firewalld` when active, and prints the resulting `IP:Port` plus a curl test command.

Security note: the generated Dante config uses `socksmethod: none`, so restrict access with firewall allowlisting when possible.

## `setup-mtproto.sh`

Installs and configures Telegram's MTProto proxy from `TelegramMessenger/MTProxy`.

Recommended install command:

```bash
wget -qO- https://raw.githubusercontent.com/shatxlab/shell-scripts/main/setup-mtproto.sh | sudo bash -s -- 443,8443 8888 proxy.example.com
```

Parameters:

- First argument: MTProto proxy ports, comma-separated. Default: `443,8443`.
- Second argument: local stats port. Default: `8888`.
- Third argument: domain for the Telegram proxy link. Optional. You can also set `SERVER_DOMAIN` or `DOMAIN`.

The script supports Debian/Ubuntu and RHEL-like distributions, opens all MTProto ports through `ufw` or `firewalld` when active, creates a systemd service, and prints the Telegram proxy link.

