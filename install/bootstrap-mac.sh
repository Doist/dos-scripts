#!/usr/bin/env bash
set -euo pipefail

REPO="Doist/doist-os"
TARGET_DIR="${DOIST_OS_DIR:-$HOME/doist-os}"
LOG_FILE="${TMPDIR:-/tmp}/doist-bootstrap-$(date +%Y%m%d-%H%M%S).log"

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

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_brew_on_path() {
  if [ -x /opt/homebrew/bin/brew ]; then
    export PATH="/opt/homebrew/bin:$PATH"
  elif [ -x /usr/local/bin/brew ]; then
    export PATH="/usr/local/bin:$PATH"
  fi
}

ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    say "  - Xcode Command Line Tools already installed"
    return
  fi

  say "  - Triggering Xcode Command Line Tools installer"
  xcode-select --install >/dev/null 2>&1 || true
  echo
  echo "Finish the Xcode Command Line Tools install prompt, then rerun this command."
  echo "Log file: $LOG_FILE"
  exit 1
}

ensure_homebrew() {
  ensure_brew_on_path
  if has_cmd brew; then
    say "  - Homebrew already installed"
    return
  fi

  say "  - Installing Homebrew"
  say "    Homebrew may prompt for your macOS password."
  # Homebrew's NONINTERACTIVE mode skips the confirmation prompt, but it also
  # suppresses the sudo password prompt and fails with a misleading
  # "needs to be an Administrator" error for fresh admin accounts. Force the
  # installer into interactive mode and feed the return key automatically so
  # sudo can still prompt on the controlling terminal.
  {
    echo
    echo "[$(date +%Y-%m-%dT%H:%M:%S)] /bin/bash -c yes \"\" | INTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  } >>"$LOG_FILE"
  /bin/bash -c 'yes "" | INTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' 2>&1 | tee -a "$LOG_FILE" || fail "Installing Homebrew"
  ensure_brew_on_path
  has_cmd brew || fail "Homebrew installed but brew is still not in PATH"
}

ensure_brew_package() {
  local formula="$1"
  local binary="$2"
  local label="$3"

  if has_cmd "$binary"; then
    say "  - $label already installed"
    return
  fi

  run_quiet "Installing $label" brew install "$formula"
  has_cmd "$binary" || fail "$label installed but '$binary' is still not available"
}

ensure_gh_auth() {
  if gh auth status >/dev/null 2>&1; then
    say "  - GitHub CLI already authenticated"
    return
  fi

  say "  - Starting GitHub login in your browser"
  gh auth login --web --git-protocol https --hostname github.com || fail "GitHub authentication failed"
}

clone_repo() {
  if [ -d "$TARGET_DIR/.git" ]; then
    say "  - Repo already cloned at $TARGET_DIR"
    run_quiet "Pulling latest changes" git -C "$TARGET_DIR" pull --rebase origin main
    return
  fi

  if [ -e "$TARGET_DIR" ] && [ ! -d "$TARGET_DIR/.git" ]; then
    fail "Target path exists but is not a git repo: $TARGET_DIR"
  fi

  run_quiet "Cloning $REPO into $TARGET_DIR" gh repo clone "$REPO" "$TARGET_DIR"
}

run_repo_setup() {
  [ -x "$TARGET_DIR/scripts/setup.sh" ] || chmod +x "$TARGET_DIR/scripts/setup.sh" || true
  [ -f "$TARGET_DIR/scripts/setup.sh" ] || fail "Missing setup script at $TARGET_DIR/scripts/setup.sh"

  say "  - Running Doist OS setup script"
  (
    cd "$TARGET_DIR"
    ./scripts/setup.sh
  ) >>"$LOG_FILE" 2>&1 || fail "Repository setup script failed"
}

main() {
  : >"$LOG_FILE"

  local os
  os="$(uname -s)"

  echo "Doist OS bootstrap"
  echo "Log file: $LOG_FILE"

  case "$os" in
    Darwin)
      echo
      echo "==> Preparing macOS prerequisites"
      ensure_xcode_clt
      ensure_homebrew
      ensure_brew_package git git "Git CLI"
      ensure_brew_package gh gh "GitHub CLI"
      ;;
    Linux)
      echo
      echo "Linux bootstrap is not yet supported by this one-liner."
      echo "Please use your distro package manager to install git + gh, then clone $REPO and run ./scripts/setup.sh"
      exit 1
      ;;
    *)
      fail "Unsupported operating system: $os"
      ;;
  esac

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
