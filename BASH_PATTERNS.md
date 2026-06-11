# Bash Patterns — Universal Library

> Every bash pattern below is battle-tested in production (in a working night-shift system running daily since early 2026). When the wizard generates `run.sh` or any other bash file for a user, it pulls from here verbatim. Do NOT improvise these patterns — every gotcha is documented inline.

Each pattern has:
- **Pattern ID** (referenced by templates: `{{ pattern.<id> }}`)
- **What it does** (one line)
- **Snippet** (the bash, with comments)
- **Gotchas** (issues paid for in production — keep the inline comments verbatim)

---

## P1. Atomic lock (single-instance enforcement)

**What:** prevent two copies of the agent from running concurrently.

```bash
# Atomic lock via mkdir (POSIX-atomic across filesystems). Not flock (not on
# macOS by default) and not lockfile (non-atomic). PID stored inside for stale detection.
LOCK_DIR="$ROUTINE_DIR/.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_PID_FILE"
    return 0
  fi
  local prior_pid
  prior_pid="$(cat "$LOCK_PID_FILE" 2>/dev/null || echo '')"
  if [[ -n "$prior_pid" ]] && kill -0 "$prior_pid" 2>/dev/null; then
    log_both "FATAL: lock held by live PID $prior_pid — refusing to start a second instance"
    emit_json error lock_held prior_pid="$prior_pid"
    return 1
  fi
  log_both "Stale lock found (PID '$prior_pid' not running) — clearing"
  emit_json warn stale_lock_cleared prior_pid="$prior_pid"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null && echo $$ > "$LOCK_PID_FILE"
}

release_lock() {
  if [[ -f "$LOCK_PID_FILE" ]]; then
    local owner; owner="$(cat "$LOCK_PID_FILE" 2>/dev/null || echo '')"
    [[ "$owner" == "$$" ]] && rm -rf "$LOCK_DIR"
  fi
}
```

**Gotchas:**
- `mkdir` is the only POSIX-atomic primitive for this. `touch | test` is not.
- Stale-lock cleanup is mandatory or one crash bricks future runs.

---

## P2. PATH setup (must run BEFORE any tool lookup)

**What:** launchd's default PATH is bare `/usr/bin:/bin:/usr/sbin:/sbin` — Homebrew + `~/.local/bin` aren't in it. Set PATH **before** any `command -v` check.

```bash
# launchd's default PATH is /usr/bin:/bin:/usr/sbin:/sbin — Homebrew (`gh`,
# `gtimeout`, etc.) and ~/.local/bin (claude) are NOT in it. Set PATH BEFORE
# any tool lookup. Failed preflight reports of "✗ gh missing" are usually 
# this, not actual missing binary.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Reduce git index.lock contention between this script and the user's IDE
# running git status/fetch in the same repo
export GIT_OPTIONAL_LOCKS=0
```

---

## P3. Heartbeat writer (background subshell)

**What:** mechanically write a heartbeat every N seconds so external watchers know the agent is alive.

```bash
HEARTBEAT_INTERVAL=300  # 5 min — well under the 30-min staleness threshold
HEARTBEAT_PID_FILE="$LOG_DIR/heartbeat.pid"

start_heartbeat_writer() {
  # CAPTURE PARENT PID AT FUNCTION CALL TIME. Inside the subshell $PPID points to
  # init (PID 1), NOT to the parent script — zsh inheritance quirk. Production
  # bug 2026-05-19: heartbeat writer's `kill -0 $PPID` was checking init instead
  # of run.sh and the subshell died silently. Pass $$ in explicitly.
  local parent_pid=$$
  local hb_log="$LOG_DIR/heartbeat-writer.log"
  (
    # DON'T inherit set -u — any transient undefined var kills the loop.
    # Production bug fingerprint from 2026-05-19: exactly this.
    set +u
    exec 2>>"$hb_log"
    echo "[$(date -u +%FT%TZ)] heartbeat_writer start (parent=$parent_pid)" >&2
    if ! command -v jq >/dev/null 2>&1; then
      echo "no jq — exiting" >&2; exit 0
    fi
    while true; do
      sleep "$HEARTBEAT_INTERVAL"
      if ! kill -0 "$parent_pid" 2>/dev/null; then
        echo "[$(date -u +%FT%TZ)] parent gone, exit" >&2
        exit 0
      fi
      # Touch local heartbeat file
      date -u +%FT%TZ > "$LOG_DIR/last-heartbeat.txt"

      # Optionally push to coord gist (multi-machine mode — gated by env var
      # set by run.sh when execution_mode == "both"). Lets the OTHER mode
      # see liveness via gh gist view. Failures non-fatal (don't kill the
      # heartbeat loop if a single gh call hiccups).
      if [[ -n "${COORD_GIST_ID:-}" ]] && command -v gh >/dev/null 2>&1; then
        HB_NOW="$(date -u +%FT%TZ)"
        printf '{"last_heartbeat_utc":"%s","by_mode":"%s","pid":%s}' \
          "$HB_NOW" "${NIGHT_SHIFT_MODE:-local}" "$parent_pid" \
          | gh gist edit "$COORD_GIST_ID" -f heartbeat.json - 2>/dev/null || true
      fi
    done
  ) &
  echo $! > "$HEARTBEAT_PID_FILE"
}

stop_heartbeat_writer() {
  [[ -f "$HEARTBEAT_PID_FILE" ]] || return 0
  local pid; pid="$(cat "$HEARTBEAT_PID_FILE")"
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  rm -f "$HEARTBEAT_PID_FILE"
}
```

**Gotchas:**
- `$PPID` inside a subshell does NOT reliably point to the script. Use `local parent_pid=$$` before forking.
- `set -u` in subshell + any transient undefined var = silent death. Always `set +u` first.

---

## P4. Stall watchdog (kill agent if frozen)

**What:** if the agent's tool-use JSONL stops being written for N seconds, the LLM is hung — kill it.

```bash
STALL_THRESHOLD=${STALL_THRESHOLD:-3600}  # 60min idle = hung
FIRST_ACTIVITY_DEADLINE=${FIRST_ACTIVITY_DEADLINE:-600}  # 10min with ZERO tool_use = SDK initial-hang
STALL_KILL_ENABLED=${STALL_KILL_ENABLED:-1}
STALL_INTERVAL=60
STALL_WATCHDOG_PID_FILE="$LOG_DIR/stall-watchdog.pid"

start_stall_watchdog() {
  local parent_pid=$$
  local sw_log="$LOG_DIR/stall-watchdog.log"
  local watchdog_start_epoch; watchdog_start_epoch=$(date -u +%s)
  # IGNORE prior-run JSONL files mistakenly returned by ls -t. Stale-prior-run
  # guard — if jsonl file is older than the start of this watchdog, skip it.
  local stale_grace_s=120
  local min_valid_mtime=$(( watchdog_start_epoch - stale_grace_s ))
  (
    set +u
    exec 2>>"$sw_log"
    # The encoded CC project dir (Claude Code's per-project transcript storage)
    local proj_dir
    proj_dir="$HOME/.claude/projects/$(pwd | sed -e 's|^/||' -e 's|/|-|g' | sed 's|^|-|')"
    while true; do
      sleep "$STALL_INTERVAL"
      kill -0 "$parent_pid" 2>/dev/null || exit 0

      # Find the LIVE claude's JSONL. Bind to the fd the running claude holds
      # open (via lsof -p) FIRST — `ls -t` alone can pick a sibling/subagent
      # JSONL in a shared proj_dir that still has tool_use and mask a hung main
      # session (a stall fired ~8000s late that way). Fall back to ls -t only if
      # lsof yields nothing.
      local jsonl="" _wd_cpid
      _wd_cpid=$(pgrep -f "claude --print.*$ROUTINE_DIR" | head -1)
      if [[ -n "$_wd_cpid" ]]; then
        jsonl=$(lsof -p "$_wd_cpid" -Fn 2>/dev/null \
          | sed -n 's/^n\(.*[.]jsonl\)$/\1/p' \
          | grep -F "$proj_dir" | head -1)
      fi
      if [[ -z "$jsonl" || ! -f "$jsonl" ]]; then
        jsonl=$(find "$proj_dir" -name '*.jsonl' -mmin -720 -print0 2>/dev/null \
          | xargs -0 ls -t 2>/dev/null | head -1)
      fi
      [[ -z "$jsonl" ]] && continue

      # FIRST-ACTIVITY watchdog: catch the SDK initial-hang (claude writes a
      # thinking block then goes silent with ZERO tool_use). Reference the
      # WATCHDOG START epoch, NOT the jsonl mtime — the startup thinking block
      # keeps mtime fresh so an mtime check would never trip. Kills within 10min
      # vs the 60min idle threshold; 5s TERM→KILL grace (vs 30s) for a fast retry.
      local now; now=$(date -u +%s)
      if (( now - watchdog_start_epoch > FIRST_ACTIVITY_DEADLINE )) \
         && (( STALL_KILL_ENABLED )) \
         && ! grep -q '"type":"tool_use"' "$jsonl" 2>/dev/null; then
        if [[ -n "$_wd_cpid" ]] && kill -0 "$_wd_cpid" 2>/dev/null; then
          echo "[$(date -u +%FT%TZ)] INITIAL-HANG: 0 tool_use after $((now-watchdog_start_epoch))s — TERMing claude $_wd_cpid" >&2
          kill -TERM "$_wd_cpid" 2>/dev/null; sleep 5
          kill -0 "$_wd_cpid" 2>/dev/null && kill -KILL "$_wd_cpid" 2>/dev/null
          exit 0
        fi
      fi

      local mtime; mtime=$(stat -f %m "$jsonl" 2>/dev/null)
      [[ -z "$mtime" ]] && continue

      # Stale-prior-run guard
      if (( mtime < min_valid_mtime )); then
        continue
      fi

      local age=$(( now - mtime ))

      if (( age > STALL_THRESHOLD )); then
        local claude_pid
        # Match by ROUTINE_DIR — every claude invocation from run.sh has
        # --add-dir "$RUNTIME_DIR" which contains ROUTINE_DIR as prefix.
        # No literal placeholder — substituted at template render time.
        claude_pid=$(pgrep -f "claude --print.*$ROUTINE_DIR" | head -1)
        if [[ -n "$claude_pid" ]] && kill -0 "$claude_pid" 2>/dev/null; then
          echo "[$(date -u +%FT%TZ)] STALL: JSONL idle ${age}s — TERMing claude $claude_pid" >&2
          kill -TERM "$claude_pid" 2>/dev/null
          # 30s grace, then SIGKILL
          sleep 30
          kill -0 "$claude_pid" 2>/dev/null && kill -KILL "$claude_pid" 2>/dev/null
          # Emit forensic event
          # (the main script will detect exit code 143 or 137 and act)
        fi
        exit 0
      fi
    done
  ) &
  echo $! > "$STALL_WATCHDOG_PID_FILE"
}

stop_stall_watchdog() {
  [[ -f "$STALL_WATCHDOG_PID_FILE" ]] || return 0
  local pid; pid="$(cat "$STALL_WATCHDOG_PID_FILE")"
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  rm -f "$STALL_WATCHDOG_PID_FILE"
}
```

**Gotchas:**
- `ls -t` returns prior-run JSONLs (stale-prior-run guard) AND can pick a sibling/subagent JSONL that still has tool_use, masking a hung main session — bind to the live claude's open fd via `lsof -p` first; fall back to `ls -t` only if lsof is empty.
- The first-activity branch references the watchdog START epoch, not jsonl mtime — the SDK writes a thinking block before hanging, so an mtime check never trips on an initial hang.
- TERM then KILL — TERM-only doesn't always work if claude is in a tight loop.

---

## P5. Idempotent cleanup trap

**What:** runs on EVERY exit path (EXIT/INT/TERM/HUP). Restores state, scrubs logs, releases lock.

```bash
CLEANUP_RAN=0

cleanup() {
  local exit_code="${1:-0}"
  if [[ "$CLEANUP_RAN" -eq 1 ]]; then return 0; fi
  CLEANUP_RAN=1

  emit_json info cleanup_start exit_code="$exit_code"
  log_both "Cleanup starting (exit=$exit_code)"

  # 1) Stop background subshells
  stop_heartbeat_writer
  stop_stall_watchdog

  # 2) Kill caffeinate
  if [[ -n "${CAFFEINATE_PID:-}" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
    kill "$CAFFEINATE_PID" 2>/dev/null || true
  fi

  # 3) Scrub credential-shaped strings from logs (defensive — even if no leak,
  #    this catches future misconfigured tool that prints creds to stderr)
  for f in "$LOG" "$JSON_LOG"; do
    [[ -f "$f" ]] || continue
    sed -i '' -E \
      -e 's/ghp_[A-Za-z0-9_-]{20,}/ghp_<REDACTED>/g' \
      -e 's/ghs_[A-Za-z0-9_-]{20,}/ghs_<REDACTED>/g' \
      -e 's/github_pat_[A-Za-z0-9_-]+/github_pat_<REDACTED>/g' \
      -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/xox?-<REDACTED>/g' \
      -e 's/AKIA[0-9A-Z]{16}/AKIA<REDACTED>/g' \
      -e 's/sk-ant-[A-Za-z0-9_-]+/sk-ant-<REDACTED>/g' \
      "$f" 2>/dev/null || true
  done

  # 4) Log retention — keep last 30 days
  if [[ -d "$LOG_DIR" ]]; then
    find "$LOG_DIR" -type f \( -name "*.log" -o -name "*.jsonl" \) -mtime +30 -delete 2>/dev/null || true
  fi

  # 5) Multi-machine coord audit — fires when this mode finished exit=0 but
  #    never touched the coord-written flag. Catches the "wrote gist but
  #    skipped Drive" failure mode that causes the OTHER mode to spuriously
  #    duplicate today's brief tomorrow. Only audits on normal (exit=0)
  #    non-dry-run completions; skips on legitimate skip paths.
  COORD_WRITTEN_FLAG="$LOG_DIR/coord-written.flag"
  if [[ "$exit_code" -eq 0 && "${DRY_RUN:-0}" -eq 0 ]] && [[ -n "${COORD_GIST_ID:-}" ]]; then
    if [[ ! -f "$COORD_WRITTEN_FLAG" ]]; then
      # Suppress on legitimate skip — agent ran but STEP 0.4 short-circuited
      # because today's brief is already shipped. In that case there's no
      # coord-write to perform: the original successful run already wrote it.
      if grep -qE "Today's (local|remote) mode already completed|^routine SKIP|^skip:|coordination-skip" "$LOG" 2>/dev/null; then
        emit_json info coord_write_skipped_legit
      else
        emit_json warn coord_write_missing message="agent finished exit=0 but never wrote coord flag — other mode may spuriously re-run"
        log_both "WARNING: coord-written.flag missing after exit=0 — agent skipped coord write; other mode may not detect this success"
      fi
    else
      emit_json info coord_write_verified
    fi
  fi

  # 6) Drop wrapper.pid
  rm -f "$LOG_DIR/wrapper.pid"

  # 7) Release lock LAST
  release_lock

  emit_json info cleanup_done exit_code="$exit_code"
}

trap 'cleanup $?' EXIT
trap 'log_both "Received SIGINT";  exit 130' INT
trap 'log_both "Received SIGTERM"; exit 143' TERM
# SIGHUP: IGNORE. An unattended nightly agent must survive terminal/session
# hangup mid-run — the wall (P19), stall watchdog (P4), caffeinate (P9) and the
# launchd SIGTERM still bound a stuck run. A SIGHUP-fatal trap once killed a
# HEALTHY rate-limit sleep mid-wait (resets 8pm) → no brief that night.
trap '' HUP
```

**Gotchas:**
- `CLEANUP_RAN=1` guard prevents double-execution if EXIT fires after explicit `cleanup` call.
- Release lock LAST — anything that errors after releasing means a second instance can race in.
- Do NOT exit on SIGHUP — ignore it (`trap '' HUP`). Exiting on hangup kills unattended runs (and in-flight rate-limit sleeps); the other layers bound a genuinely stuck run.

---

## P6. Structured JSONL logging

**What:** machine-readable event log alongside text log. Used by dashboards, triage, meta-agent.

```bash
RUN_DATE_LOCAL="$(date +%Y-%m-%d)"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="$ROUTINE_DIR/runs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/${RUN_DATE_LOCAL}.log"
JSON_LOG="$LOG_DIR/${RUN_DATE_LOCAL}.jsonl"

emit_json() {
  local level="$1" event="$2"; shift 2
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local extras="" arg k v
  for arg in "$@"; do
    k="${arg%%=*}"; v="${arg#*=}"
    # Full JSON escape — newline/tab/quote in a stderr line would break parsers
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\r'/\\r}"
    v="${v//$'\t'/\\t}"
    extras+="\"$k\":\"$v\","
  done
  printf '{"ts":"%s","level":"%s","event":"%s","run_ts":"%s","pid":%s,%s"mode":"local"}\n' \
    "$ts" "$level" "$event" "$RUN_TS" "$$" "$extras" >> "$JSON_LOG"
}

log_both() {
  echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"
}
```

---

## P7. Timeout binary resolution (gtimeout / timeout / perl-alarm)

**What:** macOS BSD doesn't ship `timeout`. Resolve once at startup, use through wrapper.

```bash
resolve_timeout_bin() {
  if command -v gtimeout >/dev/null 2>&1; then echo gtimeout
  elif command -v timeout >/dev/null 2>&1; then echo timeout
  elif command -v perl >/dev/null 2>&1; then echo "perl-alarm"
  else echo ""; fi
}
TIMEOUT_BIN="$(resolve_timeout_bin)"

# Use site:
run_with_timeout() {
  local secs="$1"; shift
  case "$TIMEOUT_BIN" in
    gtimeout|timeout)
      "$TIMEOUT_BIN" --kill-after=30 "$secs" "$@"
      ;;
    perl-alarm)
      perl -e '$t=shift; alarm $t; exec @ARGV; die "exec failed"' "$secs" "$@"
      ;;
    *)
      log_both "WARNING: no timeout mechanism — running unwrapped"
      "$@"
      ;;
  esac
}
```

---

## P8. Network recovery (wifi toggle when DNS fails — macOS)

**What:** if the agent runs overnight and wifi flakes, it would hang on the first network call. Probe + recover before the agent starts.

```bash
network_probe() {
  ping -c 1 -W 1500 1.1.1.1 >/dev/null 2>&1 || return 1
  ping -c 1 -W 1500 github.com >/dev/null 2>&1 || return 2
  return 0
}

# Auto-detect wifi interface name (en0 default, but laptops with multiple
# adapters can vary — read from networksetup)
WIFI_IFACE="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{getline; print $2; exit}')"
WIFI_IFACE="${WIFI_IFACE:-en0}"

if ! network_probe; then
  PROBE_RC=$?
  log_both "WARN: network probe failed (rc=$PROBE_RC) — toggling Wi-Fi ($WIFI_IFACE)"
  emit_json warn network_probe_failed probe_rc="$PROBE_RC" iface="$WIFI_IFACE"
  networksetup -setairportpower "$WIFI_IFACE" off 2>>"$LOG" || true
  sleep 3
  networksetup -setairportpower "$WIFI_IFACE" on 2>>"$LOG" || true
  RECOVERED=0
  for i in 1 2 3 4 5 6; do
    sleep 5
    network_probe && { RECOVERED=1; break; }
  done
  if (( RECOVERED )); then
    log_both "Network recovered after Wi-Fi toggle (waited $((i*5))s)"
  else
    log_both "ERROR: network still down — aborting cleanly"
    exit 1
  fi
fi
```

---

## P9. caffeinate (keep Mac awake during run)

**What:** prevent macOS sleep mid-run. Without this, lid-close or idle = SIGKILL.

```bash
# -t = hard auto-exit. Bound above the largest hard wall, so cleanup() kills
# caffeinate before its own timer fires. Belt-and-suspenders: if cleanup
# crashes, -t still releases the sleep assertion eventually.
caffeinate -dis -t 32400 &
CAFFEINATE_PID=$!
```

Cleanup releases (caller must call this in cleanup() — extractor is intentionally `text` fenced so it does NOT get inlined alongside the start block above):
```text
[[ -n "${CAFFEINATE_PID:-}" ]] && kill "$CAFFEINATE_PID" 2>/dev/null || true
```

---

## P10. User-repo snapshot/restore (protect uncommitted work)

**What:** before the agent touches the user's project repo (e.g., to test a patch), snapshot via `git stash --include-untracked`. After: restore.

```bash
# Snapshot before mutation
ub_snapshot() {
  local id="$1"
  local stash_msg
  stash_msg="night-shift-snap-${id}-$(date -u +%FT%TZ)"
  # Record current branch BEFORE we stash, so ub_restore can return here
  git -C "$USER_REPO" branch --show-current > "$ROUTINE_DIR/.active-branch" 2>/dev/null
  git -C "$USER_REPO" stash push --include-untracked --quiet -m "$stash_msg"
  echo "$stash_msg" > "$ROUTINE_DIR/.active-snapshot"
}

# Restore — apply not pop, so stash stays in list if conflict
ub_restore() {
  local stash_msg; stash_msg="$(cat "$ROUTINE_DIR/.active-snapshot" 2>/dev/null)"
  [[ -z "$stash_msg" ]] && return 0
  # Force-checkout to original branch first
  local orig_branch; orig_branch="$(cat "$ROUTINE_DIR/.active-branch" 2>/dev/null)"
  [[ -n "$orig_branch" ]] && git -C "$USER_REPO" checkout --quiet "$orig_branch"
  # Find stash by message
  local stash_ref
  stash_ref="$(git -C "$USER_REPO" stash list | grep -F "$stash_msg" | head -1 | cut -d: -f1)"
  if [[ -n "$stash_ref" ]]; then
    if git -C "$USER_REPO" stash apply --quiet "$stash_ref"; then
      git -C "$USER_REPO" stash drop --quiet "$stash_ref"
      rm -f "$ROUTINE_DIR/.active-snapshot"
    else
      log_both "WARN: stash apply had conflicts — KEPT in stash list for manual recovery"
    fi
  fi
}
```

**Gotchas:**
- `--include-untracked` is critical — without it, untracked files leak into the patch-test phase.
- Use `apply` not `pop` — if conflict, stash stays in list (recoverable). Pop would silently lose it.

---

## P11. Anti-jitter (midnight launchd race)

**What:** launchd may fire a few hundred ms early. A 00:00 local CEST run = 22:00 prev-day UTC — without a small sleep, you can compute yesterday's date.

```bash
# Belt-and-suspenders: 3s sleep at script start when wall-clock crosses a date
# boundary at the trigger time.
sleep 3
```

---

## P12. Preflight check (validate environment)

**What:** before any heavy work, verify all required binaries, files, and permissions are in place. Fail loudly with clear remediation.

```bash
preflight() {
  local fails=0 warns=0
  local OUT=""
  
  add_line() { OUT+="$1"$'\n'; }
  check() {
    local label="$1" cmd="$2" level="${3:-fail}"
    if eval "$cmd" >/dev/null 2>&1; then
      add_line "  ✓ $label"
    else
      if [[ "$level" == "warn" ]]; then
        add_line "  ⚠ $label"
        warns=$((warns + 1))
      else
        add_line "  ✗ $label"
        fails=$((fails + 1))
      fi
    fi
  }

  add_line "=== PREFLIGHT ==="
  add_line "[binaries]"
  check "claude CLI"   "command -v claude"
  check "git"          "command -v git"
  check "gh"           "command -v gh"
  check "gh authed"    "gh auth status"  warn
  check "jq"           "command -v jq"

  add_line "[files]"
  check "prompt.md"    "[[ -r \"$PROMPT\" ]]"
  check "settings.json"  "python3 -c 'import json,sys; json.load(open(\"$SETTINGS\"))'"

  add_line "[macOS TCC]"
  if git -C "$USER_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    add_line "  ✓ USER_REPO git access (TCC OK)"
  else
    local tcc_err; tcc_err=$(git -C "$USER_REPO" rev-parse --git-dir 2>&1)
    if echo "$tcc_err" | grep -qi "operation not permitted\|permission denied"; then
      add_line "  ✗ USER_REPO TCC BLOCKED — System Settings → Privacy → Full Disk Access → add /bin/zsh + git"
      fails=$((fails + 1))
    fi
  fi

  echo "$OUT"
  if (( fails > 0 )); then return 1; fi
  if (( warns > 0 )); then return 2; fi
  return 0
}
```

**Caller's responsibility:**

The template (or whoever inlines P12) calls `preflight` itself — pattern only defines the function. This keeps the template in control of invocation order (e.g., `--preflight` flag may short-circuit before pattern P11 / lock acquire).

**Use-site reminder for the caller** — DO NOT use `if ! preflight; then pf_rc=$?`. The `!` operator's exit code (0) overwrites `$?` in the then-block. Capture rc BEFORE branching:

<!-- Documentation block (not extracted into rendered files — note the `text` fence, not `bash`). -->
```text
preflight
PF_RC=$?
if [[ $PF_RC -eq 1 ]]; then
  log_both "FATAL: preflight failed"
  exit 1
elif [[ $PF_RC -eq 2 ]]; then
  log_both "Preflight passed with warnings"
fi
```

---

## P13. Auto-resume retry loop (with rate-limit awareness)

**What:** if claude dies (stall watchdog killed it, hard timeout, crash), respawn — up to N attempts. If killed by rate limit, wait + retry without counting it as an attempt.

```bash
MAX_CLAUDE_ATTEMPTS=3
MAX_RATE_LIMIT_RETRIES=3
RATE_LIMIT_RETRIES=0
ATTEMPT=1

while (( ATTEMPT <= MAX_CLAUDE_ATTEMPTS )); do
  if (( ATTEMPT > 1 )); then
    log_both "=== ATTEMPT $ATTEMPT of $MAX_CLAUDE_ATTEMPTS — RESUMING ==="
    # Respawn watchdogs if they died
    [[ ! -f "$STALL_WATCHDOG_PID_FILE" ]] && start_stall_watchdog
    [[ ! -f "$HEARTBEAT_PID_FILE" ]] && start_heartbeat_writer
  fi

  # Run claude (using P7 timeout wrapper)
  run_with_timeout "$CLAUDE_HARD_TIMEOUT_SEC" claude --print --permission-mode bypassPermissions \
    --add-dir "$RUNTIME_DIR" \
    < "$PROMPT" 2>&1 | tee -a "$LOG"
  CLAUDE_EXIT="${pipestatus[1]:-0}"
  # NB: ${pipestatus[1]} is zsh; bash would use ${PIPESTATUS[0]}. This script
  # is zsh (#!/usr/bin/env zsh shebang). Without ${pipestatus[1]} you'd read
  # tee's exit code (always 0) instead of claude's.

  case "$CLAUDE_EXIT" in
    124) log_both "ERR: hit hard timeout" ;;
    137) log_both "ERR: required SIGKILL" ;;
    143) log_both "ERR: SIGTERM (probably stall watchdog)" ;;
    0)   log_both "OK: claude exited cleanly" ;;
    *)   log_both "WARN: exit $CLAUDE_EXIT" ;;
  esac

  # Check if delivery is complete (recipe-defined success criterion)
  if delivery_complete; then break; fi

  # Check for skip flag (agent declared idempotent no-op)
  if [[ -f "$LOG_DIR/${RUN_DATE_LOCAL}-skip.flag" ]]; then
    log_both "Skip declared — done"
    break
  fi

  # Rate-limit / overload detection. Detection + reset parsing live in PURE
  # functions defined at the top of run.sh (log_has_rate_limit / log_has_overload
  # / compute_rate_limit_reset_epoch) with hidden --selftest entrypoints, so a
  # test harness can BEHAVIORALLY exercise them on synthetic logs (see Gotchas).
  # Detection must recognize the Max-plan interactive message
  # "You've hit your limit · resets 4am (TZ)" — a bare "usage limit reached"
  # regex misses it, so the night hard-fails instead of deferring to the reset.
  if log_has_rate_limit "$LOG"; then
    if (( RATE_LIMIT_RETRIES < MAX_RATE_LIMIT_RETRIES )); then
      RATE_LIMIT_RETRIES=$((RATE_LIMIT_RETRIES + 1))
      # Reset parsing handles ISO ("will reset at <ISO>", constrained to
      # reset-lines so log-prefix timestamps can't hijack it), wall-clock
      # ("resets 4am (TZ)"), and relative ("in 4h 12m") — see run.sh top.
      reset_epoch=$(compute_rate_limit_reset_epoch "$LOG")
      wait_for=$(( reset_epoch - $(date -u +%s) )); (( wait_for < 30 )) && wait_for=30
      log_both "Rate limited — sleeping ${wait_for}s until reset (not counting attempt)"
      sleep "$wait_for"
      continue
    fi
  elif log_has_overload "$LOG"; then
    if (( RATE_LIMIT_RETRIES < MAX_RATE_LIMIT_RETRIES )); then
      # Transient 529 — short backoff (120s, 240s, 360s), NOT an hours-long wait.
      RATE_LIMIT_RETRIES=$((RATE_LIMIT_RETRIES + 1))
      sleep $(( RATE_LIMIT_RETRIES * 120 ))
      continue
    fi
  fi

  if (( ATTEMPT < MAX_CLAUDE_ATTEMPTS )); then
    sleep 30
  fi
  ATTEMPT=$((ATTEMPT + 1))
done
```

**Gotchas:**
- `${pipestatus[1]:-0}` (zsh, 1-indexed, lowercase). bash equivalent is `${PIPESTATUS[0]}`.
- `tee` always exits 0 — without pipestatus you'd read 0 not claude's real code.
- **Extract detection + parsing into pure functions with hidden `--selftest-detect` / `--selftest-reset-epoch` entrypoints, then assert them behaviorally.** Presence-grepping the regex is NOT enough: a matcher or parser can go dead (shadowed match, mis-anchored grep, a regex literal that also appears in comments) while the grep that "proves" it stays green — you'd only discover it at the live reset hour. `validate.sh` runs the rendered `run.sh --selftest-*` on synthetic logs and asserts the computed classification + reset epoch.
- **Distinguish 429 / usage-limit (wait until the real reset — possibly hours) from 529 overload (transient — short backoff).** One shared fixed-sleep path means a ~15-min Anthropic outage burns the whole retry budget instead of riding it out.

---

## P14. Skip policy (don't re-run if today already shipped)

**What:** if today's brief was already delivered (maybe via manual trigger earlier), don't redo work. Two layers: agent-written flag + tail-grep fallback.

```bash
SKIP_FLAG="$LOG_DIR/${RUN_DATE_LOCAL}-skip.flag"

# In the agent prompt: when finishing successfully, write the flag file.
# In the wrapper: read it deterministically (no brittle log grep).

if [[ -f "$SKIP_FLAG" ]]; then
  log_both "Skip flag exists from earlier run — exiting"
  emit_json info skip_via_flag
  exit 0
fi
```

---

## P15. Anti-jitter + wrapper.pid for dashboard liveness

**What:** write the wrapper's own PID — source of truth for "is the run alive" for any external observer.

```bash
echo "$$" > "$LOG_DIR/wrapper.pid"
# Cleanup removes it
```

---

## P16. SIGTERM forensic dump

**What:** when claude exits 143 (SIGTERM) without context, dump system state — sleep events, related processes, caffeinate state. Catches "why did it die at 11:31?" questions.

```bash
case "$CLAUDE_EXIT" in
  143)
    if ! grep -q claude_stalled_killed "$JSON_LOG" 2>/dev/null; then
      log_both "WARN: SIGTERM (143) — origin unknown. Forensic dump follows."
      {
        echo "=== SIGTERM forensic dump ($(date -u +%FT%TZ)) ==="
        ps -p $$ -o pid,ppid,etime,command 2>/dev/null
        echo "-- related processes --"
        pgrep -lf 'claude --print|caffeinate|run\.sh' 2>/dev/null
        echo "-- caffeinate alive? --"
        [[ -n "${CAFFEINATE_PID:-}" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null && echo "yes" || echo "no"
        echo "-- system sleep/wake (last 30m) --"
        log show --predicate 'eventMessage CONTAINS[c] "Sleep" OR eventMessage CONTAINS[c] "wake"' --last 30m --style compact 2>/dev/null | head -50
      } >> "$LOG" 2>&1 || true
    fi
    ;;
esac
```

---

## P17. Git working-tree safety (clean reset before per-PR work)

**What:** before checking out a branch in the worktree, force-clean. Without this, leftover state from a prior crashed run causes `checkout` to abort silently.

```bash
git_worktree_reset_clean() {
  local wt="$1"
  # ORDER MATTERS: if prior attempt died with uncommitted edits on a feature
  # branch, going straight to `checkout --detach origin/main` aborts with
  # "your local changes would be overwritten" and the script silently continues
  # on the dirty branch. Force-drop state BEFORE detaching.
  git -C "$wt" reset --hard HEAD --quiet 2>/dev/null || true
  git -C "$wt" clean -fd --quiet 2>/dev/null || true   # -fd not -fdx: preserve node_modules cache
  git -C "$wt" checkout --detach origin/main --quiet 2>/dev/null || true
  git -C "$wt" reset --hard origin/main --quiet 2>/dev/null || true
}
```

**Gotchas:**
- `-fd` not `-fdx` — `-x` nukes ignored files including node_modules.
- `reset --hard HEAD` BEFORE `checkout --detach` — otherwise dirty files block the checkout.

---

## P18. SwiftBar dashboard (5s refresh, with safety quirks)

**What:** macOS menubar widget showing agent state.

```bash
#!/usr/bin/env zsh
# <bitbar.title>Night Shift Agent</bitbar.title>
# <bitbar.refresh>5s</bitbar.refresh>

# INTENTIONALLY NOT `set -u` — SwiftBar plugins that crash mid-render disappear
# from the menubar until next refresh. Many probes here legitimately return
# empty values; missing-var crashes are worse than a stale row.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Helper: timeout-bound execution (since gtimeout reliability under SwiftBar
# was flaky, use perl-alarm directly)
with_timeout() {
  local secs="$1"; shift
  perl -e 'use POSIX ":sys_wait_h"; my $secs=shift; my $pid=fork; if($pid==0){exec @ARGV} local $SIG{ALRM}=sub{kill 9,$pid;exit 124}; alarm $secs; waitpid $pid,0; exit $?>>8' "$secs" "$@" 2>/dev/null
}

# Cache layer: avoid re-fetching gh API on every refresh
CACHE_DIR="$HOME/.cache/night-shift-agent"
mkdir -p "$CACHE_DIR"
cached() {
  local key="$1" max_age="$2" cmd="${@:3}"
  local cache_file="$CACHE_DIR/$key"
  if [[ -f "$cache_file" ]]; then
    local age=$(( $(date +%s) - $(stat -f %m "$cache_file") ))
    if (( age < max_age )); then
      cat "$cache_file"
      return 0
    fi
  fi
  eval "$cmd" > "$cache_file" 2>/dev/null
  cat "$cache_file"
}

# Render state from wrapper.pid + last log
INSTALL="${NIGHT_SHIFT_INSTALL:-$HOME/night-shift-agent}"
if [[ -f "$INSTALL/runs/wrapper.pid" ]] && kill -0 "$(cat $INSTALL/runs/wrapper.pid)" 2>/dev/null; then
  echo "🌙 RUNNING"
else
  echo "🌙"
fi
echo "---"
# … menu items …
```

---

## P19. Absolute wall-clock suicide timer (hard-bound the WHOLE run)

The per-attempt timeout (P7), stall watchdog (P4), and caffeinate (P9) each bound
a *single* claude attempt or the sleep assertion — **nothing bounds the whole
run**. A run that loops retries/auto-resume for hours holds the atomic lock (P1),
so the next scheduled run sees a live holder and refuses → zero output that night.
This timer hard-bounds total wall time even if every other layer fails.

Four hard-won invariants are baked in (do not "simplify" them away):
- **Poll loop, NOT a single `sleep $ABS_MAX`.** A single `sleep` does NOT tick
  during macOS system sleep — a wedged run survived 27–51h with `sleep 32400`
  still alive. Poll `date +%s` against an absolute deadline so it still fires
  after a sleep/wake cycle.
- **Snapshot descendants BEFORE killing.** claude sits in its OWN process group
  (the perl-alarm setpgrp in P7), so SIGTERMing main first reparents+hides it and
  a plain group-kill misses it. Collect the live descendant PIDs while the tree is
  intact, then kill.
- **Self-pid exclusion** via zsh `$sysparams[pid]` — the timer must never kill
  itself before it finishes the sweep.
- **Self-abort if the lock is no longer ours** — a late orphan timer is a
  harmless no-op, never a kill of an unrelated recycled PID.

```bash
# Arm AFTER lock acquire (P1) and AFTER caffeinate (P9) so it can outlive both.
# ABS_MAX must sit at/above the caffeinate -t ceiling (P9).
ABS_MAX_S="${NIGHT_SHIFT_ABS_MAX_SEC:-32400}"   # 9h default; env-overridable for fire-drills
_run_self=$$
(
  trap '' HUP INT TERM
  zmodload zsh/system 2>/dev/null
  _me="${sysparams[pid]:-0}"
  _dl=$(($(date +%s) + ABS_MAX_S))
  while (( $(date +%s) < _dl )); do sleep 60; done            # poll — survives macOS sleep
  # self-abort: run already ended cleanly (lock released / pid recycled) → no-op
  [[ -f "$LOCK_PID_FILE" && "$(cat "$LOCK_PID_FILE" 2>/dev/null)" == "$_run_self" ]] || exit 0
  ps -p "$_run_self" -o command= 2>/dev/null | grep -q 'run[.]sh' || exit 0
  printf '{"ts":"%s","level":"error","event":"abs_wall_suicide","abs_max_s":%s,"pid":%s}\n' \
    "$(date -u +%FT%TZ)" "$ABS_MAX_S" "$_run_self" >> "$JSON_LOG" 2>/dev/null || true
  typeset -a _vics
  _collect() { local p=$1 c; for c in ${(f)"$(pgrep -P $p 2>/dev/null)"}; do [[ $c == $_me ]] && continue; _vics+=$c; _collect $c; done; }
  _collect "$_run_self"
  kill -TERM "$_run_self" 2>/dev/null            # graceful → EXIT trap → release_lock
  sleep 30
  for c in $_vics; do kill -KILL "$c" 2>/dev/null; done       # force-kill claude et al (pgroup-proof)
  kill -KILL "$_run_self" 2>/dev/null
  [[ -f "$LOCK_PID_FILE" && "$(cat "$LOCK_PID_FILE" 2>/dev/null)" == "$_run_self" ]] && rm -rf "$LOCK_DIR" 2>/dev/null
) &
SUICIDE_PID=$!
```

**Companion: age-based lock reclamation (extend P1's `acquire_lock`).** A liveness
check alone is insufficient — a wedged run that holds the lock for hours blocks
every future run. Inside the `kill -0 "$prior_pid"` branch, before the FATAL
refusal, reclaim a holder older than the absolute ceiling:

```bash
prior_age_s="$(ps -o etimes= -p "$prior_pid" 2>/dev/null | tr -d ' ')"
if [[ -n "$prior_age_s" ]] && (( prior_age_s > ${NIGHT_SHIFT_ABS_MAX_SEC:-32400} )); then
  log_both "Lock holder $prior_pid is ${prior_age_s}s old (> ABS_MAX) — runaway; reclaiming"
  for c in $(pgrep -P "$prior_pid" 2>/dev/null); do kill -KILL "$c" 2>/dev/null; done
  kill -KILL "$prior_pid" 2>/dev/null
  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_PID_FILE"; return 0; fi
fi
```

The same timer applies to any long-running sibling (a meta-agent loop, a
pre-night analyzer) with its own cap (e.g. 1h / 2h) and its own lock pid-file.

---

## P20. Layered MCP config (headless `claude --print` does NOT inherit `~/.claude.json`)

The single highest-impact reliability bug class: a headless `claude --print`
invocation does **not** inherit the `mcpServers` from `~/.claude.json` the way an
interactive session does. Without an explicit `--mcp-config`, the agent silently
loses every MCP tool (issue tracker, chat, error monitor, …) and ships degraded
briefs — for nights on end, while `claude mcp list` still says "Connected". Pass
`--mcp-config` (and `--settings`) on **every** claude invocation. Layer a
committed config (no secrets) under a gitignored local overlay (OAuth secrets):

```bash
# Resolve once near the top of the script. Prefer the gitignored local overlay
# (holds OAuth secrets) when present, else the committed public config.
if [[ -f "$ROUTINE_DIR/mcp-config.local.json" ]]; then
  MCP_CONFIG="$ROUTINE_DIR/mcp-config.local.json"
else
  MCP_CONFIG="$ROUTINE_DIR/mcp-config.json"
fi

# …and on EVERY `claude --print` arm (main run, resume, probe, meta):
#   --settings   "$SETTINGS" \
#   --mcp-config "$MCP_CONFIG" \
```

Gotcha: `mcp-config.local.json` is gitignored and holds secrets — never commit
it. This pairs with P21 (a preflight probe that the surface actually loaded).

---

## P21. MCP tool-surface preflight probe (WARNING, not a hard fail)

Fail-fast detection that the headless MCP surface (P20) actually loaded
end-to-end, BEFORE the agent burns 20+ minutes on a degraded brief. Critically
wired as a **warning**, not a hard fail — a degraded brief (local + error-monitor)
beats no brief, the real run has hours plus the first-activity watchdog (P4), so a
probe timeout never implies the run would fail. Reserve hard-fail only for a
genuinely missing/corrupt config file.

```bash
preflight_mcp_probe() {   # returns 0 ok / 1 degraded — caller treats 1 as warn++
  local probe_prompt='List the tool names available to you that start with "mcp__". On the final line print exactly: PROBE_RESULT count=<N>'
  local cargs=("$HOME/.local/bin/claude" --print --model haiku --permission-mode bypassPermissions \
               --settings "$SETTINGS" --mcp-config "$MCP_CONFIG" --output-format text)
  # 180s cap: warm MCP startup is ~25s, but a COLD launchd start (OAuth refresh +
  # cold prompt-cache) can blow past 120s. Use the P7 timeout resolution.
  local probe_out
  if command -v gtimeout >/dev/null 2>&1; then
    probe_out=$(gtimeout --kill-after=15 180 "${cargs[@]}" <<<"$probe_prompt" 2>&1 || true)
  elif command -v timeout >/dev/null 2>&1; then
    probe_out=$(timeout --kill-after=15 180 "${cargs[@]}" <<<"$probe_prompt" 2>&1 || true)
  else
    probe_out=$("${cargs[@]}" <<<"$probe_prompt" 2>&1 || true)
  fi
  local result_line; result_line=$(echo "$probe_out" | grep -oE 'PROBE_RESULT count=[0-9]+' | tail -1)
  [[ -z "$result_line" ]] && { echo "PROBE_NO_SENTINEL (cold start? degraded run continues)" >&2; return 1; }
  local n="${result_line##*count=}"
  (( n > 0 )) && { echo "PROBE_OK count=$n"; return 0; }
  echo "PROBE_DEGRADED count=0" >&2; return 1
}
```

---

## P22. launchd-safe detached spawn (double-fork + setsid)

When a launchd-managed run spawns a post-run sibling (a meta-agent, a notifier),
plain `nohup … &` is NOT enough: `nohup` ignores SIGHUP but **not** the SIGTERM
launchd sends to the whole job process group when the main job exits — every
spawned sibling dies after writing a few bytes. Double-fork + `POSIX::setsid()`
moves the grandchild to a new session adopted by PID 1, off the job's group:

```bash
SPAWN_LOG="$LOG_DIR/spawn-$(date -u +%FT%H%M).log" /usr/bin/perl -e '
  use POSIX ();
  exit 0 if fork;                 # parent exits
  POSIX::setsid();                # new session — leave the launchd job process group
  exit 0 if fork;                 # double-fork — grandchild orphaned to PID 1
  open(STDIN, "<", "/dev/null");
  open(STDOUT, ">", $ENV{SPAWN_LOG}) or die "open stdout: $!";
  open(STDERR, ">&", \*STDOUT)       or die "dup stderr: $!";
  exec @ARGV or die "exec: $!";
' "$ROUTINE_DIR/meta-agent.sh" </dev/null &
disown 2>/dev/null || true
```

(macOS ships `/usr/bin/perl`; the agent is macOS-only.)

---

## P23. API-readiness gate (before each claude attempt)

The post-sleep-wake failure mode: the Mac wakes from a multi-hour sleep and the
scheduled run launches claude ~1min later into a not-yet-ready network → the SDK
hangs on its first API call ("socket closed unexpectedly"). A ping is not enough —
DNS can resolve before TLS/HTTPS works. Make a real HTTPS request; any http_code
means the socket is live. Pair with a night-cutoff so retry work never drifts
into the workday (attempt 1 always runs — a late single attempt beats nothing;
only *retries* are time-gated).

```bash
api_health_gate() {   # best-effort: returns 1 after the cap but launches anyway (P4 catches a hang)
  local tries="${1:-12}" i code
  for (( i=1; i<=tries; i++ )); do
    code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/messages 2>/dev/null)
    if [[ "$code" =~ ^[1-9][0-9][0-9]$ ]]; then
      (( i > 1 )) && log_both "API readiness: reachable after $i tries (http $code)"
      return 0
    fi
    log_both "API readiness: not ready (curl code='${code:-none}') — retry $i/$tries in 15s"
    sleep 15
  done
  log_both "API readiness: still not ready after ~3min — launching anyway (watchdog catches a hang)"
  return 1
}

# Night cutoff, inside the retry branch (ATTEMPT > 1): never START a retry past
# the cutoff hour (work would land in the user's morning). 24h clock, local tz.
#   _h=$(date +%H); _h=${_h#0}; _h=${_h:-0}
#   if (( _h >= ${NIGHT_SHIFT_CUTOFF_HOUR:-3} && _h < 12 )); then break; fi
```

---

## Inline bash gotchas (preserve these comments verbatim in any generated bash)

These are paid-for-in-production warnings. When you generate a bash file, copy the relevant comment block.

### G1. zsh `local status` clash
```bash
# zsh has a read-only built-in `status` (exit code of last cmd). Using
# `local status` under set -u aborts the function silently. Use a different
# variable name (e.g. gist_status) — never bare `status`.
```

### G2. BSD xargs has no `-r`
```bash
# BSD xargs (macOS) lacks `-r` (no-run-if-empty). Use while-read loop:
something_listing | while read -r line; do
  [[ -n "$line" ]] && do_thing "$line"
done
```

### G3. macOS bash 3.2 lacks `mapfile`
```bash
# Don't use mapfile — not in macOS bash 3.2. Use:
ARR=()
while IFS= read -r line; do
  ARR+=("$line")
done < <(some_command)
```

### G4. macOS BSD `date -j -u -f`
```bash
# macOS BSD date — use:  date -j -u -f "%Y-%m-%d" "$value" +%s
# GNU `date -d "$value" +%s` is NOT available on stock macOS; don't use it.
```

### G5. Don't export GITHUB_TOKEN globally
```bash
# Security: do NOT export GITHUB_TOKEN globally. The agent's Bash tool calls
# inherit it, and a prompt-injection in ingested PR/Slack content could
# exfiltrate. Use `gh` CLI (keychain-backed) OR call `gh auth token` JIT in
# a single pipeline when truly needed.
```

### G6. `tee` clobbers $? — always use `${pipestatus[1]}` (zsh) / `${PIPESTATUS[0]}` (bash)
```bash
# `cmd | tee file` — $? reads tee's exit code (always 0), not cmd's. Use:
cmd | tee file
RC="${pipestatus[1]:-0}"   # zsh — lowercase, 1-indexed
# or for bash:
# RC="${PIPESTATUS[0]:-0}" # bash — uppercase, 0-indexed
```

### G7. `if ! preflight; then pf_rc=$?` is a trap
```bash
# The `!` operator inverts $? to 0 in the then-block. ALWAYS:
preflight
PF_RC=$?
if [[ $PF_RC -eq 1 ]]; then ...
# NOT:
# if ! preflight; then PF_RC=$?; ...  # PF_RC is always 0 here!
```

### G8. `$PPID` is unreliable in subshells
```bash
# Inside a subshell, $PPID often points to init (PID 1), NOT the parent script.
# zsh inherits it across subshells but the value is the ORIGINAL parent at
# script start. Capture parent PID via $$ BEFORE forking:
local parent_pid=$$
( ... use $parent_pid in subshell ... ) &
```

---

## Pattern usage in templates

Templates reference patterns by ID via `{{ pattern.P1 }}`, etc. The wizard renders each into the appropriate place:

| Template file | Patterns used |
|---|---|
| `run.sh.template` | P1, P2, P3, P4, P5, P6, P7, P8, P9, P11, P12, P13, P14, P15, P16, P17, P19, P20, P21, P22, P23 |
| `swiftbar.sh.template` | P2, P18 |
| `meta-agent.sh.template` | P1, P2, P3, P4, P5, P6, P7, P19, P22 |
| `protect-user-state.sh.template` | P10, P17 |
| `triage.sh.template` | P2, P6, G3, G4 |

P19–P23 are the June reliability hardening: the absolute wall-clock suicide timer
(P19), layered MCP config (P20) + its preflight probe (P21), launchd-safe detached
spawn (P22), and the API-readiness gate (P23). All are gated behind resilience
flags so a minimal install renders none of them.

Plus every generated bash file gets the relevant G-block comments inline as warnings.
