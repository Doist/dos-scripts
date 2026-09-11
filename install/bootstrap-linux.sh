#!/usr/bin/env bash

set -euo pipefail

REPO="Doist/todoist-os"
TARGET_DIR="" # Resolved after Git is available.
LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/todoist-os-bootstrap-XXXXXX")"

PACKAGE_MANAGER=""
SUDO=()
APT_UPDATED=0
PACMAN_UPDATED=0

say() { echo "$1"; }

fail() {
  echo
  echo "Bootstrap failed: $1"
  echo "Log file: $LOG_FILE"
  if [ -s "$LOG_FILE" ]; then
    echo "Last output:"
    tail -n 25 "$LOG_FILE"
  fi
  exit 1
}

run_quiet() {
  local step="$1"
  shift
  say "  - $step"
  {
    echo
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*"
  } >>"$LOG_FILE"
  "$@" >>"$LOG_FILE" 2>&1 || fail "$step"
}

run_root_quiet() {
  local step="$1"
  shift
  if [ "${#SUDO[@]}" -gt 0 ]; then
    run_quiet "$step" "${SUDO[@]}" "$@"
  else
    run_quiet "$step" "$@"
  fi
}

run_root_shell_quiet() {
  local step="$1"
  local script="$2"
  if [ "${#SUDO[@]}" -gt 0 ]; then
    run_quiet "$step" "${SUDO[@]}" bash -lc "$script"
  else
    run_quiet "$step" bash -lc "$script"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

has_ca_certificates() {
  [ -f /etc/ssl/certs/ca-certificates.crt ] \
    || [ -f /etc/pki/tls/certs/ca-bundle.crt ] \
    || [ -f /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem ] \
    || [ -f /etc/ssl/ca-bundle.pem ]
}

detect_package_manager() {
  if has_cmd apt-get; then
    PACKAGE_MANAGER="apt"
  elif has_cmd dnf; then
    PACKAGE_MANAGER="dnf"
  elif has_cmd yum; then
    PACKAGE_MANAGER="yum"
  elif has_cmd zypper; then
    PACKAGE_MANAGER="zypper"
  elif has_cmd pacman; then
    PACKAGE_MANAGER="pacman"
  else
    fail "Unsupported Linux distribution: could not detect apt-get, dnf, yum, zypper, or pacman"
  fi
}

configure_privilege() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=()
    return
  fi

  if has_cmd sudo; then
    SUDO=(sudo)
    return
  fi

  fail "sudo is required to install Linux prerequisites"
}

ensure_apt_updated() {
  if [ "$APT_UPDATED" -eq 1 ]; then
    return
  fi

  run_root_quiet "Refreshing apt package index" apt-get update
  APT_UPDATED=1
}

ensure_pacman_updated() {
  if [ "$PACMAN_UPDATED" -eq 1 ]; then
    return
  fi

  run_root_quiet "Refreshing pacman package database and upgrading installed packages" pacman -Syu --noconfirm
  PACMAN_UPDATED=1
}

install_system_packages() {
  local step="$1"
  shift

  case "$PACKAGE_MANAGER" in
    apt)
      ensure_apt_updated
      run_root_quiet "$step" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf)
      run_root_quiet "$step" dnf install -y "$@"
      ;;
    yum)
      run_root_quiet "$step" yum install -y "$@"
      ;;
    zypper)
      run_root_quiet "$step" zypper install -y "$@"
      ;;
    pacman)
      ensure_pacman_updated
      run_root_quiet "$step" pacman -S --needed --noconfirm "$@"
      ;;
  esac
}

ensure_network_tools() {
  if has_cmd curl && has_ca_certificates; then
    say "  - Network bootstrap tools already installed"
    return
  fi

  install_system_packages "Installing network bootstrap tools" curl ca-certificates
  has_cmd curl || fail "Network bootstrap tools installed but 'curl' is still not available"
  has_ca_certificates || fail "Network bootstrap tools installed but the CA certificate bundle is still unavailable"
}

ensure_git() {
  if has_cmd git; then
    say "  - Git already installed"
    return
  fi

  install_system_packages "Installing Git CLI" git
  has_cmd git || fail "Git installed but 'git' is still not available"
}

ensure_gh() {
  if has_cmd gh; then
    say "  - GitHub CLI already installed"
    return
  fi

  case "$PACKAGE_MANAGER" in
    apt)
      run_root_shell_quiet "Configuring GitHub CLI apt repository" '
set -e
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
mkdir -p -m 755 /etc/apt/sources.list.d
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
'
      APT_UPDATED=0
      ensure_apt_updated
      install_system_packages "Installing GitHub CLI" gh
      ;;
    dnf)
      run_root_shell_quiet "Configuring GitHub CLI dnf repository" '
set -e
if dnf config-manager addrepo --help >/dev/null 2>&1; then
  dnf install -y dnf5-plugins
  dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo
else
  dnf install -y dnf-command\(config-manager\)
  dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
fi
'
      run_root_quiet "Installing GitHub CLI" dnf install -y gh --repo gh-cli
      ;;
    yum)
      run_root_shell_quiet "Configuring GitHub CLI yum repository" '
set -e
type -p yum-config-manager >/dev/null || yum install -y yum-utils
yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
'
      run_root_quiet "Installing GitHub CLI" yum install -y gh
      ;;
    zypper)
      run_root_shell_quiet "Configuring GitHub CLI zypper repository" '
set -e
zypper addrepo https://cli.github.com/packages/rpm/gh-cli.repo gh-cli
zypper ref
'
      run_root_quiet "Installing GitHub CLI" zypper install -y gh
      ;;
    pacman)
      install_system_packages "Installing GitHub CLI" github-cli
      ;;
  esac

  has_cmd gh || fail "GitHub CLI installed but 'gh' is still not available"
}

ensure_gh_auth() {
  if gh auth status >/dev/null 2>&1; then
    say "  - GitHub CLI already authenticated"
    return
  fi

  say "  - Starting GitHub login in your browser"
  gh auth login --web --git-protocol https --hostname github.com || fail "GitHub authentication failed"
}

select_target_dir() {
  # Keep existing checkouts in place, including the older README's Documents path.
  if [ -n "${TODOIST_OS_DIR:-}" ]; then
    TARGET_DIR="$TODOIST_OS_DIR"
    return
  fi
  if [ -n "${DOIST_OS_DIR:-}" ]; then
    TARGET_DIR="$DOIST_OS_DIR"
    return
  fi
  local candidate
  local found=""
  for candidate in "$HOME/todoist-os" "$HOME/doist-os" "$HOME/Documents/todoist-os" "$HOME/Documents/doist-os"; do
    if [ -e "$candidate/.git" ]; then
      if [ -n "$found" ]; then
        fail "Multiple workspace checkouts found. Set TODOIST_OS_DIR to the one you want to update."
      fi
      found="$candidate"
    fi
  done
  TARGET_DIR="${found:-$HOME/todoist-os}"
}

validate_checkout() {
  local remote branch changes
  remote="$(git -C "$TARGET_DIR" config --get remote.origin.url)" || fail "Cannot read the existing checkout's origin."
  if [[ ! "$remote" =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)[Dd]oist/(doist-os|todoist-os)(\.git)?$ ]]; then
    fail "The target checkout is not the TodoistOS upstream. Set TODOIST_OS_DIR to your TodoistOS checkout."
  fi
  branch="$(git -C "$TARGET_DIR" branch --show-current)" || fail "Cannot read the existing checkout's branch."
  [ "$branch" = "main" ] || fail "Switch the target checkout to main before rerunning setup."
  changes="$(git -C "$TARGET_DIR" status --porcelain)" || fail "Cannot read the existing checkout status."
  [ -z "$changes" ] || fail "Commit or stash changes in the target checkout before rerunning setup."
}

clone_repo() {
  select_target_dir
  if [ -e "$TARGET_DIR/.git" ]; then
    validate_checkout
    say "  - Repo already cloned at $TARGET_DIR"
    run_quiet "Pulling latest changes" git -C "$TARGET_DIR" pull --rebase origin main
    return
  fi

  if [ -e "$TARGET_DIR" ] && [ ! -e "$TARGET_DIR/.git" ]; then
    fail "Target path exists but is not a git repo: $TARGET_DIR"
  fi

  run_quiet "Cloning $REPO into $TARGET_DIR" gh repo clone "$REPO" "$TARGET_DIR"
}

run_repo_setup() {
  [ -x "$TARGET_DIR/scripts/setup.sh" ] || chmod +x "$TARGET_DIR/scripts/setup.sh" || true
  [ -f "$TARGET_DIR/scripts/setup.sh" ] || fail "Missing setup script at $TARGET_DIR/scripts/setup.sh"

  say "  - Running TodoistOS setup script"
  (
    cd "$TARGET_DIR"
    ./scripts/setup.sh
  ) >>"$LOG_FILE" 2>&1 || fail "Repository setup script failed"
}

main() {
  : >"$LOG_FILE"

  echo "TodoistOS bootstrap"
  echo "Log file: $LOG_FILE"

  detect_package_manager
  configure_privilege

  echo
  echo "==> Preparing Linux prerequisites"
  echo "  - Detected package manager: $PACKAGE_MANAGER"
  ensure_network_tools
  ensure_git
  ensure_gh

  echo
  echo "==> Accessing private repository"
  ensure_gh_auth
  clone_repo

  echo
  echo "==> Running repository setup"
  run_repo_setup

  echo
  echo "Bootstrap complete."
  echo "Repository: $TARGET_DIR"
}

main "$@"
