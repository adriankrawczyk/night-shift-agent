#!/usr/bin/env bash
# Night Shift Agent — one-command launcher
#
# Usage:
#   bash install.sh                  # interactive install
#   bash install.sh --dir <PATH>     # install to non-default location
#   bash install.sh --update         # pull latest installer + re-launch wizard
#   bash install.sh --no-launch      # clone/update only, don't open claude
#   bash install.sh --collect-logs   # copy the install diagnostic log to clipboard
#
# Remote one-liner:
#   curl -fsSL https://raw.githubusercontent.com/adriankrawczyk/night-shift-agent/main/install.sh | bash

set -euo pipefail

# === Platform gate ===
if [ "$(uname -s)" != "Darwin" ]; then
  printf '\033[31mNight Shift Agent requires macOS.\033[0m\n' >&2
  printf 'The installer uses launchd, caffeinate, networksetup, plutil, osascript, and SwiftBar — all macOS-specific.\n' >&2
  exit 1
fi

# === Config ===
REPO_URL="${NIGHT_SHIFT_REPO_URL:-https://github.com/adriankrawczyk/night-shift-agent}"
INSTALLER_DIR="${NIGHT_SHIFT_INSTALLER_DIR:-$HOME/.night-shift-installer}"
LAUNCH=1
UPDATE_ONLY=0
COLLECT_LOGS=0

# === Install diagnostic log ===
# Captures EVERYTHING about a build at someone's machine — env, tool versions,
# clone/update, integrity, then (via the wizard) every phase, scan, MCP install,
# render and problem — so the whole thing can be handed back for debugging.
# Lives outside the repo so a re-clone never wipes it.
INSTALL_LOG_DIR="${NIGHT_SHIFT_INSTALL_LOG_DIR:-$HOME/.config/night-shift-agent/install-logs}"
INSTALL_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
INSTALL_LOG="$INSTALL_LOG_DIR/install-$INSTALL_RUN_ID.log"

# === Arg parsing ===
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) INSTALLER_DIR="$2"; shift 2 ;;
    --update) UPDATE_ONLY=1; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --collect-logs) COLLECT_LOGS=1; shift ;;
    -h|--help)
      sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown flag: $1 (use --help)" >&2; exit 2 ;;
  esac
done

c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

# ilog: append a timestamped event to the install diagnostic log (best-effort,
# never fatal). Use for every meaningful step + every problem.
ilog() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${1:-info}" "${*:2}" >> "$INSTALL_LOG" 2>/dev/null || true; }

# collect_logs: scrub credential-shaped strings, bundle the newest install log +
# the wizard state, copy to clipboard so the user can paste it back for debugging.
collect_logs() {
  local latest
  latest="$(ls -t "$INSTALL_LOG_DIR"/install-*.log 2>/dev/null | head -1)"
  if [ -z "$latest" ]; then
    c_red "No install logs found in $INSTALL_LOG_DIR"
    c_red "Run an install first (bash install.sh), then re-run --collect-logs."
    exit 1
  fi
  local state="$HOME/.config/night-shift-agent/state.json"
  local bundle
  bundle="$({
    echo "===== Night Shift Agent — install diagnostic bundle ====="
    echo "host:        $(hostname -s 2>/dev/null)"
    echo "generated:   $(date -u +%FT%TZ)"
    echo "macOS:       $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
    echo "installer:   $INSTALLER_DIR"
    echo "log file:    $latest"
    echo ""
    echo "----- wizard state (answers; secrets are stored separately and NOT included) -----"
    cat "$state" 2>/dev/null || echo "(no state.json — wizard may not have started)"
    echo ""
    echo "----- install + wizard log -----"
    cat "$latest"
  } | sed -E \
      -e 's/ghp_[A-Za-z0-9_-]{20,}/ghp_<REDACTED>/g' \
      -e 's/ghs_[A-Za-z0-9_-]{20,}/ghs_<REDACTED>/g' \
      -e 's/github_pat_[A-Za-z0-9_-]+/github_pat_<REDACTED>/g' \
      -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/xox?-<REDACTED>/g' \
      -e 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-<REDACTED>/g' \
      -e 's/AKIA[0-9A-Z]{16}/AKIA<REDACTED>/g')"
  if command -v pbcopy >/dev/null 2>&1 && printf '%s' "$bundle" | pbcopy 2>/dev/null; then
    c_green "✓ Copied install diagnostics to clipboard ($(printf '%s' "$bundle" | wc -l | tr -d ' ') lines). Paste it to your helper."
  else
    c_dim "pbcopy unavailable — the bundle is the file: $latest"
  fi
  echo "  (newest of: $(ls -1 "$INSTALL_LOG_DIR"/install-*.log 2>/dev/null | wc -l | tr -d ' ') logs in $INSTALL_LOG_DIR)"
}

# --collect-logs is a standalone action — do it and exit before any install work.
if [ "$COLLECT_LOGS" -eq 1 ]; then
  collect_logs
  exit 0
fi

# Open the log. Tee install.sh's own output into it so the captured narrative
# matches what the user saw; fds are restored before handing off to the wizard
# (so claude's interactive REPL is unaffected).
mkdir -p "$INSTALL_LOG_DIR" 2>/dev/null || true
{
  echo "===== install run $INSTALL_RUN_ID ====="
  echo "started:   $(date -u +%FT%TZ)"
  echo "macOS:     $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null) ($(uname -m))"
  echo "shell:     ${SHELL:-?}   bash: ${BASH_VERSION:-?}"
  echo "git:       $(git --version 2>/dev/null)"
  echo "jq:        $(jq --version 2>/dev/null)"
  echo "claude:    $(claude --version 2>/dev/null || echo 'not found')"
  echo "gh:        $(gh --version 2>/dev/null | head -1 || echo 'not found')"
  echo "installer: $INSTALLER_DIR   repo: $REPO_URL"
  echo "flags:     UPDATE_ONLY=$UPDATE_ONLY LAUNCH=$LAUNCH"
  echo "========================================="
} >> "$INSTALL_LOG" 2>/dev/null || true
exec 3>&1 4>&2
exec > >(tee -a "$INSTALL_LOG") 2>&1

# === Preflight ===
c_blue "Night Shift Agent — installer"
echo ""

ilog info preflight_start "checking required tools: git jq claude"
missing=()
for bin in git jq claude; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done

if [ ${#missing[@]} -gt 0 ]; then
  ilog error preflight_missing_tools "${missing[*]}"
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
  command -v "$bin" >/dev/null 2>&1 || { c_dim "  optional: $bin not found (some features may be limited)"; ilog warn optional_tool_missing "$bin"; }
done
ilog info preflight_ok "all required tools present"

# === Clone or update ===
# Dev-only paths: they live in the repo (CI + contributors need them) but the
# installing user never reads them. We sparse-checkout everything EXCEPT these,
# so a fresh install fetches only the files the wizard actually uses.
SPARSE_EXCLUDES=(tests .github validate.sh DESIGN.md STAGED-BACKPORT.md)
apply_sparse_excludes() {
  # Non-cone sparse patterns: include all, then re-exclude the dev-only paths.
  local pats=('/*') p
  for p in "${SPARSE_EXCLUDES[@]}"; do pats+=("!/$p"); done
  git -C "$INSTALLER_DIR" sparse-checkout set --no-cone "${pats[@]}"
}

if [ -d "$INSTALLER_DIR/.git" ]; then
  c_dim "Installer at $INSTALLER_DIR — pulling latest"
  if pull_out="$(git -C "$INSTALLER_DIR" pull --ff-only 2>&1)"; then
    apply_sparse_excludes 2>/dev/null || true   # converge older full installs to slim
    ilog info installer_pull_ok "$pull_out"
  else
    ilog error installer_pull_failed "$pull_out"
    c_red "git pull failed in $INSTALLER_DIR (uncommitted changes? wrong remote?)"
    exit 1
  fi
elif [ -d "$INSTALLER_DIR" ]; then
  # Directory exists but isn't a git repo
  if [ -f "$INSTALLER_DIR/META_PROMPT.md" ] && [ -f "$INSTALLER_DIR/wizard-questions.yaml" ]; then
    c_dim "Installer at $INSTALLER_DIR (not a git checkout — using as-is)"
    ilog warn installer_not_git "using existing non-git checkout at $INSTALLER_DIR"
  else
    ilog error installer_invalid_dir "$INSTALLER_DIR exists but lacks META_PROMPT.md/wizard-questions.yaml"
    c_red "$INSTALLER_DIR exists but isn't a valid installer (missing META_PROMPT.md or wizard-questions.yaml)"
    c_red "Move it aside or pass --dir <other-path>."
    exit 1
  fi
else
  c_dim "Cloning $REPO_URL → $INSTALLER_DIR (sparse — dev tooling stays in the repo, not fetched)"
  # Blobless + sparse: dev-only blobs are never downloaded.
  if clone_out="$(git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$INSTALLER_DIR" 2>&1)" \
     && sparse_out="$(apply_sparse_excludes 2>&1)"; then
    ilog info installer_cloned "$REPO_URL -> $INSTALLER_DIR (sparse: excluded ${SPARSE_EXCLUDES[*]})"
  else
    # Fallback for old git / servers without partial-clone: full clone, then
    # strip the dev-only paths locally so the user still ends up with a slim tree.
    ilog warn installer_sparse_failed "${clone_out:-}${sparse_out:-} — falling back to full clone + prune"
    rm -rf "$INSTALLER_DIR"
    if clone_out="$(git clone --depth 1 "$REPO_URL" "$INSTALLER_DIR" 2>&1)"; then
      ( cd "$INSTALLER_DIR" && rm -rf "${SPARSE_EXCLUDES[@]}" )
      ilog info installer_cloned "$REPO_URL -> $INSTALLER_DIR (full+pruned: ${SPARSE_EXCLUDES[*]})"
    else
      ilog error installer_clone_failed "$clone_out"
      c_red "git clone failed: $clone_out"
      exit 1
    fi
  fi
fi

# === Integrity check ===
required=(META_PROMPT.md wizard-questions.yaml BASH_PATTERNS.md MCP_PATTERNS.md PERSONA_BUILDER.md COORD_PATTERN.md VERSION templates recipes phases)
for f in "${required[@]}"; do
  if [ ! -e "$INSTALLER_DIR/$f" ]; then
    ilog error integrity_failed "missing $INSTALLER_DIR/$f"
    c_red "Integrity check failed: missing $INSTALLER_DIR/$f"
    c_red "Run: bash $INSTALLER_DIR/install.sh --update"
    exit 1
  fi
done
INSTALLER_VERSION="$(cat "$INSTALLER_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
INSTALLER_COMMIT="$(git -C "$INSTALLER_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ilog info installer_ready "v${INSTALLER_VERSION:-?} @ ${INSTALLER_COMMIT}"
c_green "✓ Installer ready at $INSTALLER_DIR (v${INSTALLER_VERSION:-?} @ ${INSTALLER_COMMIT})"

if [ "$UPDATE_ONLY" -eq 1 ] || [ "$LAUNCH" -eq 0 ]; then
  ilog info skip_launch "UPDATE_ONLY=$UPDATE_ONLY LAUNCH=$LAUNCH — not launching wizard"
  echo ""
  c_dim "Skip-launch mode. To start the wizard manually:"
  echo "  NIGHT_SHIFT_INSTALL_LOG=$INSTALL_LOG claude \"Read $INSTALLER_DIR/META_PROMPT.md and run the wizard.\""
  exit 0
fi

# === Launch wizard ===
echo ""
c_blue "Launching wizard. The first question is about setup depth (Minimal / Balanced / Full)."
c_dim "Setup takes ~20-30 min for Full tier. You can re-run with 'bash $INSTALLER_DIR/install.sh' to pick up where you left off."
c_dim "Everything is logged to $INSTALL_LOG — run 'bash $INSTALLER_DIR/install.sh --collect-logs' afterward to copy it for debugging."
echo ""

# The wizard (a separate claude process) appends to the SAME diagnostic log via
# this env var (META_PROMPT reads it). The prompt also states the path explicitly.
export NIGHT_SHIFT_INSTALL_LOG="$INSTALL_LOG"
WIZARD_PROMPT="Read $INSTALLER_DIR/META_PROMPT.md and run the Night Shift Agent installer wizard. The installer is at $INSTALLER_DIR. Append diagnostic events for every phase, scan, MCP install, render and problem to the install log at $INSTALL_LOG (also in \$NIGHT_SHIFT_INSTALL_LOG) per META_PROMPT's INSTALL DIAGNOSTIC LOG section."
ilog info wizard_handoff "exec claude — wizard now owns the log at $INSTALL_LOG"

# Detach the tee (restore original stdout/stderr) so claude's interactive REPL
# is unaffected; the wizard appends to the log directly via the env var.
exec 1>&3 2>&4

# When run via `curl … | bash`, stdin is the curl pipe (no TTY). claude REPL
# needs a TTY. Detect this and either reconnect to /dev/tty or fall back to
# printing the manual command.
if [ -t 0 ] && [ -t 1 ]; then
  # Interactive — safe to exec claude with inherited stdio
  exec claude "$WIZARD_PROMPT"
elif [ -e /dev/tty ]; then
  # Piped install (curl | bash): only STDIN is the curl pipe — stdout/stderr were
  # restored above to the ORIGINAL terminal (fd 3/4). So reattach stdin from the
  # terminal and leave stdout/stderr alone; only force them to /dev/tty if they
  # somehow aren't a TTY.
  #
  # Do NOT blindly `>/dev/tty 2>/dev/tty`: that opens a SECOND write handle to an
  # already-terminal stdout/stderr, which makes the claude CLI (Bun) crash in
  # tty.WriteStream with `EINVAL: kqueue` / `process.stderr.fd undefined` before
  # the wizard ever starts. Reattaching only stdin avoids that entirely.
  c_dim "Reconnecting to the terminal for the interactive wizard…"
  exec 0</dev/tty
  [ -t 1 ] || exec 1>/dev/tty
  [ -t 2 ] || exec 2>/dev/tty
  exec claude "$WIZARD_PROMPT"
else
  # No TTY available (CI / headless / docker without -it) — print and exit
  ilog warn no_tty "wizard not launched — no TTY; printed manual command"
  echo ""
  c_blue "No TTY detected — can't launch interactive wizard automatically."
  echo "Run this in your terminal to start the wizard:"
  echo ""
  echo "  NIGHT_SHIFT_INSTALL_LOG=$INSTALL_LOG claude \"$WIZARD_PROMPT\""
  echo ""
  exit 0
fi
