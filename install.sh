#!/usr/bin/env bash
# Night Shift Agent — one-command launcher
#
# Usage:
#   bash install.sh                  # interactive install
#   bash install.sh --dir <PATH>     # install to non-default location
#   bash install.sh --update         # pull latest installer + re-launch wizard
#   bash install.sh --no-launch      # clone/update only, don't open claude
#
# Remote one-liner:
#   curl -fsSL https://raw.githubusercontent.com/adriankrawczyk/night-shift-agent/main/install.sh | bash

set -euo pipefail

# === Platform gate ===
if [ "$(uname -s)" != "Darwin" ]; then
  printf '\033[31mNight Shift Agent v0.1 requires macOS.\033[0m\n' >&2
  printf 'The installer uses launchd, caffeinate, networksetup, plutil, osascript, and SwiftBar — all macOS-specific.\n' >&2
  exit 1
fi

# === Config ===
REPO_URL="${NIGHT_SHIFT_REPO_URL:-https://github.com/adriankrawczyk/night-shift-agent}"
INSTALLER_DIR="${NIGHT_SHIFT_INSTALLER_DIR:-$HOME/.night-shift-installer}"
LAUNCH=1
UPDATE_ONLY=0

# === Arg parsing ===
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALLER_DIR="$2"; shift 2 ;;
    --update) UPDATE_ONLY=1; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help)
      sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown flag: $1 (use --help)" >&2; exit 2 ;;
  esac
done

c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

# === Preflight ===
c_blue "Night Shift Agent — installer"
echo ""

missing=()
for bin in git jq claude; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done

if [ ${#missing[@]} -gt 0 ]; then
  c_red "Missing required tools: ${missing[*]}"
  echo ""
  case " ${missing[*]} " in
    *" git "*)    echo "  git:    install via Xcode CLT (xcode-select --install)" ;;
  esac
  case " ${missing[*]} " in
    *" jq "*)     echo "  jq:     brew install jq" ;;
  esac
  case " ${missing[*]} " in
    *" claude "*) echo "  claude: install Claude Code — https://docs.claude.com/en/docs/claude-code/quickstart" ;;
  esac
  exit 1
fi

# Optional but recommended
for bin in gh terminal-notifier; do
  command -v "$bin" >/dev/null 2>&1 || c_dim "  optional: $bin not found (some features may be limited)"
done

# === Clone or update ===
if [ -d "$INSTALLER_DIR/.git" ]; then
  c_dim "Installer at $INSTALLER_DIR — pulling latest"
  git -C "$INSTALLER_DIR" pull --ff-only --quiet || {
    c_red "git pull failed in $INSTALLER_DIR (uncommitted changes? wrong remote?)"
    exit 1
  }
elif [ -d "$INSTALLER_DIR" ]; then
  # Directory exists but isn't a git repo
  if [ -f "$INSTALLER_DIR/META_PROMPT.md" ] && [ -f "$INSTALLER_DIR/wizard-questions.yaml" ]; then
    c_dim "Installer at $INSTALLER_DIR (not a git checkout — using as-is)"
  else
    c_red "$INSTALLER_DIR exists but isn't a valid installer (missing META_PROMPT.md or wizard-questions.yaml)"
    c_red "Move it aside or pass --dir <other-path>."
    exit 1
  fi
else
  c_dim "Cloning $REPO_URL → $INSTALLER_DIR"
  git clone --depth 1 --quiet "$REPO_URL" "$INSTALLER_DIR"
fi

# === Integrity check ===
required=(META_PROMPT.md wizard-questions.yaml BASH_PATTERNS.md MCP_PATTERNS.md PERSONA_BUILDER.md COORD_PATTERN.md VERSION templates recipes phases)
for f in "${required[@]}"; do
  if [ ! -e "$INSTALLER_DIR/$f" ]; then
    c_red "Integrity check failed: missing $INSTALLER_DIR/$f"
    c_red "Run: bash $0 --update"
    exit 1
  fi
done
INSTALLER_VERSION="$(cat "$INSTALLER_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
INSTALLER_COMMIT="$(git -C "$INSTALLER_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
c_green "✓ Installer ready at $INSTALLER_DIR (v${INSTALLER_VERSION:-?} @ ${INSTALLER_COMMIT})"

if [ "$UPDATE_ONLY" -eq 1 ] || [ "$LAUNCH" -eq 0 ]; then
  echo ""
  c_dim "Skip-launch mode. To start the wizard manually:"
  echo "  claude \"Read $INSTALLER_DIR/META_PROMPT.md and run the wizard.\""
  exit 0
fi

# === Launch wizard ===
echo ""
c_blue "Launching wizard. The first question is about setup depth (Minimal / Balanced / Full)."
c_dim "Setup takes ~20-30 min for Full tier. You can re-run with 'bash $0' to pick up where you left off."
echo ""

WIZARD_PROMPT="Read $INSTALLER_DIR/META_PROMPT.md and run the Night Shift Agent installer wizard. The installer is at $INSTALLER_DIR."

# When run via `curl … | bash`, stdin is the curl pipe (no TTY). claude REPL
# needs a TTY. Detect this and either reconnect to /dev/tty or fall back to
# printing the manual command.
if [ -t 0 ] && [ -t 1 ]; then
  # Interactive — safe to exec claude with inherited stdio
  exec claude "$WIZARD_PROMPT"
elif [ -e /dev/tty ]; then
  # Piped install but a controlling TTY exists — re-attach and exec
  c_dim "Reconnecting to TTY for interactive wizard…"
  exec claude "$WIZARD_PROMPT" </dev/tty >/dev/tty 2>/dev/tty
else
  # No TTY available (CI / headless / docker without -it) — print and exit
  echo ""
  c_blue "No TTY detected — can't launch interactive wizard automatically."
  echo "Run this in your terminal to start the wizard:"
  echo ""
  echo "  claude \"$WIZARD_PROMPT\""
  echo ""
  exit 0
fi
