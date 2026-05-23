# Coordination Pattern — Multi-Machine Execution

> When the user picks Q7.1 = C ("Both, with cloud as backup"), the agent needs to coordinate between two execution machines: their local Mac (launchd) and Anthropic's cloud (claude.ai/code Schedule). This file documents the protocol the wizard generates.

For single-machine setups (Q7.1 = A or B or D), coordination is NOT needed — skip this file entirely.

---

## Why coordination

Without it:
- Local fires 00:00. Cloud fires 03:00. Both ship a brief = two emails / two PRs / duplicate state writes.
- Local crashes at 02:00 (laptop slept). Cloud at 03:00 has no way to know local died vs succeeded → either skips when it should run, or duplicates when local was successful.
- Both modes write to `state.json` simultaneously → race condition, corrupted state.

The coordination store is the single source of truth for "did anyone ship today's brief? if running, is it alive?".

---

## Coord store — two locations, dual-write

The wizard sets up **two** stores so each mode can read at least one:

### A. GitHub Gist (primary, fast, requires `gh` CLI)

Naming: gist description starts with `night-shift-coord-` followed by user's local date (Europe/Warsaw or wherever).

```bash
TODAY=$(date +%F)  # local timezone
COORD_DESC="night-shift-coord-${TODAY}"

# Find existing
GIST_ID=$(gh gist list --limit 50 | grep "$COORD_DESC" | head -1 | awk '{print $1}')

# Read
if [[ -n "$GIST_ID" ]]; then
  gh gist view "$GIST_ID" --filename coord.json > /tmp/night-shift-coord.json
fi
```

### B. Drive (fallback, works without `gh`)

Used by cloud mode (claude.ai/code) since cloud doesn't have local `gh` keychain.

Filename: `night-shift-coord-YYYY-MM-DD.json` in Drive root.

```
mcp__drive__search title='night-shift-coord-2026-05-23.json'
# If found: mcp__drive__get_file_content
# If not: mcp__drive__create_file
```

### Dual-write requirement

When a mode updates coord (heartbeat, status change), it MUST write to BOTH stores it can access. Never just one.

- Local mode (has `gh`): write gist → then write Drive.
- Cloud mode (no `gh` keychain, but has Drive MCP): write Drive only.

If a write fails partial:
- gist fail + drive success → mode logs `coord_write_partial=drive_only`, continues
- both fail → log FATAL, exit (lost coord = better than racing)

---

## Coord JSON shape

```json
{
  "schema": "1.0",
  "date_local": "2026-05-23",
  "by_mode": {
    "local": {
      "status": "running|success|failed|null",
      "started_at": "ISO-UTC|null",
      "last_heartbeat": "ISO-UTC|null",
      "completed_at": "ISO-UTC|null",
      "outputs": {
        "markdown_path": "...|null",
        "email_draft_id": "...|null",
        "gh_issue_url": "...|null",
        "slack_dm_ts": "...|null"
      }
    },
    "cloud": {
      "status": "running|success|failed|null",
      "started_at": "ISO-UTC|null",
      "last_heartbeat": "ISO-UTC|null",
      "completed_at": "ISO-UTC|null",
      "outputs": { /* same shape */ }
    }
  }
}
```

`null` everywhere = no run started yet today.

`last_heartbeat` is updated every ~5 min by whichever mode is running. The OTHER mode uses heartbeat freshness (NOT raw start time) to detect crashes.

---

## Boot sequence per mode

When a mode (local or cloud) fires:

### Step 1 — Compute today's local date
```bash
TODAY=$(date +%F)  # both modes — the maintainer-style use Europe/Warsaw if user is there
```

### Step 2 — Read coord (try both stores)
```bash
COORD_JSON=""
# Try gist first
if command -v gh >/dev/null; then
  GIST_ID=$(gh gist list --limit 50 | grep "night-shift-coord-${TODAY}" | head -1 | awk '{print $1}')
  [[ -n "$GIST_ID" ]] && COORD_JSON=$(gh gist view "$GIST_ID" --filename coord.json 2>/dev/null)
fi
# Fall back to Drive
if [[ -z "$COORD_JSON" ]]; then
  # mcp__drive__search title='night-shift-coord-${TODAY}.json' → get_file_content
  COORD_JSON=$(get_drive_coord "$TODAY")
fi
# Default if neither found
[[ -z "$COORD_JSON" ]] && COORD_JSON='{"schema":"1.0","date_local":"'$TODAY'","by_mode":{"local":{"status":null},"cloud":{"status":null}}}'
```

### Step 3 — Decide whether to proceed

```python
# Pseudocode
this_mode = ROUTINE_MODE  # "local" or "cloud"
other_mode = "cloud" if this_mode == "local" else "local"

this_state = coord.by_mode[this_mode]
other_state = coord.by_mode[other_mode]

# Decision tree:
if other_state.status == "success":
  # The other mode already shipped today. Skip.
  write_skip_flag("other-mode-completed at <other_state.completed_at>")
  exit 0

if other_state.status == "running":
  # Check heartbeat freshness
  age_min = now() - other_state.last_heartbeat
  if age_min < 30:
    # Other mode is alive — skip
    write_skip_flag("other-mode-alive heartbeat=<age_min>min")
    exit 0
  else:
    # Other mode looks crashed/hung — preempt
    log("taking over — other mode looks crashed (heartbeat age <age_min>min)")
    # Continue to mark our own status

if this_state.status == "running":
  # We're already marked running? Two cases:
  # 1. Self-resume after a prior attempt of this mode died (allowed if recent)
  # 2. True collision (another instance of same mode racing — should be impossible
  #    with our file lock, but defensive)
  if last_local_resume_marker_exists_and_today():
    log("self-resume after prior attempt killed")
    # Proceed (keep started_at, update last_heartbeat)
  else:
    log("FATAL: true collision")
    exit 1

# All other cases — proceed
mark_running()
```

### Step 4 — Mark running (dual-write)

```bash
NOW_UTC=$(date -u +%FT%TZ)
# Update coord.by_mode[$ROUTINE_MODE]:
#   status = "running"
#   started_at = NOW_UTC  (only if not resuming)
#   last_heartbeat = NOW_UTC

# Write to gist + Drive
write_coord_dual "$NEW_COORD_JSON"
```

### Step 5 — Heartbeat during run

Local mode: the wrapper's background heartbeat writer (Pattern P3) handles this. It reads the gist ID from `coord-gist-id.txt` and updates every 5 min.

Cloud mode: the agent is responsible — emit a heartbeat update after every major step (STEP 1, 2, 3 per item, 4, 5, etc.). Cloud has no wrapper to do it mechanically.

### Step 6 — On exit, finalize coord

```bash
# Set status = "success" (or "failed"), completed_at = NOW_UTC, outputs = {...}
write_coord_dual "$FINAL_COORD_JSON"
```

If the run errored before this step, the next mode picking up will see heartbeat stale > 30 min and preempt.

---

## Generated `run.sh` additions (when execution_mode == both)

The wizard's `run.sh.template` has this conditional block:

```bash
{{#if multi_machine }}
# === COORDINATION (multi-machine) ===
ROUTINE_MODE="local"  # this script is the local wrapper
TODAY=$(date +%F)
COORD_DESC="night-shift-coord-${TODAY}"

# Read coord (try gist, fall back to Drive — invocation via Python helper to handle Drive MCP not being available in bash)
# For local mode: gist always available
GIST_ID=$(gh gist list --limit 50 2>/dev/null | grep "$COORD_DESC" | head -1 | awk '{print $1}')
if [[ -n "$GIST_ID" ]]; then
  COORD_JSON=$(gh gist view "$GIST_ID" --filename coord.json 2>/dev/null)
else
  COORD_JSON='{"schema":"1.0","date_local":"'$TODAY'","by_mode":{"local":{"status":null},"cloud":{"status":null}}}'
fi

# Parse for skip decision
CLOUD_STATUS=$(echo "$COORD_JSON" | jq -r '.by_mode.cloud.status // "null"')
CLOUD_HB=$(echo "$COORD_JSON" | jq -r '.by_mode.cloud.last_heartbeat // ""')

if [[ "$CLOUD_STATUS" == "success" ]]; then
  log_both "Skip: cloud mode already shipped today's brief"
  echo "skip: cloud completed" > "$LOG_DIR/${RUN_DATE_LOCAL}-skip.flag"
  exit 0
fi

if [[ "$CLOUD_STATUS" == "running" && -n "$CLOUD_HB" ]]; then
  # Check freshness
  CLOUD_HB_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$CLOUD_HB" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE_MIN=$(( (NOW_EPOCH - CLOUD_HB_EPOCH) / 60 ))
  if (( AGE_MIN < 30 )); then
    log_both "Skip: cloud mode is alive (heartbeat ${AGE_MIN}min ago)"
    echo "skip: cloud alive" > "$LOG_DIR/${RUN_DATE_LOCAL}-skip.flag"
    exit 0
  else
    log_both "Cloud mode looks crashed/hung (heartbeat ${AGE_MIN}min stale) — taking over"
  fi
fi

# Create/update gist with our running status (dual-write to Drive happens inside the agent's prompt later via MCP)
echo "$NEW_COORD_JSON" > /tmp/night-shift-coord.json
if [[ -n "$GIST_ID" ]]; then
  gh gist edit "$GIST_ID" --filename coord.json /tmp/night-shift-coord.json
else
  GIST_ID=$(gh gist create /tmp/night-shift-coord.json --desc "$COORD_DESC" | grep -oE 'https://[^ ]+' | sed 's|.*/||')
fi
echo "$GIST_ID" > "$LOG_DIR/coord-gist-id.txt"
{{/if}}
```

And the heartbeat writer (Pattern P3) gets an additional duty when `multi_machine`:

```bash
{{#if multi_machine}}
# Heartbeat writer updates gist coord
COORD_GIST_ID_FILE="$LOG_DIR/coord-gist-id.txt"
update_coord_heartbeat() {
  [[ ! -f "$COORD_GIST_ID_FILE" ]] && return 0
  local gist_id; gist_id=$(cat "$COORD_GIST_ID_FILE")
  local now_utc; now_utc=$(date -u +%FT%TZ)
  gh gist view "$gist_id" --filename coord.json > /tmp/coord-hb.json 2>/dev/null
  jq --arg ts "$now_utc" '.by_mode.local.last_heartbeat = $ts' /tmp/coord-hb.json > /tmp/coord-hb.new.json
  mv /tmp/coord-hb.new.json /tmp/coord-hb.json
  gh gist edit "$gist_id" --filename coord.json /tmp/coord-hb.json 2>/dev/null
}
{{/if}}
```

---

## Cloud mode setup (separate from this — user does in claude.ai UI)

When the wizard finishes and `execution_mode in [cloud, both]`, it prints:

```
Cloud mode setup — manual steps (I can't automate the claude.ai UI):

1. Open https://claude.ai/code/schedules in your browser
2. Click "New Scheduled Task"
3. Schedule: <schedule from Q7.2> (cloud equivalent — pick the same hour)
4. Task prompt: paste this URL where it can read your prompt file:
   https://raw.githubusercontent.com/<gh_repo>/main/prompt.md

   Or alternatively, paste the prompt.md content directly into the task description.

5. Make sure these MCPs are enabled for cloud:
   <list of MCPs user has + which need cloud-config equivalents>

After you set it up, the cloud agent will fire on its own schedule and
coordinate with your local agent via the gist.

I've created the initial coord gist at: https://gist.github.com/<gist_id>
```

---

## Edge cases

### Race: both modes fire at exactly the same instant
- Atomic gist read returns the same baseline for both
- Both try to write running status to gist
- Last writer wins; first writer reads back, sees its own update overwritten
- First writer reads new state, sees other-mode running, picks up the skip-flag path
- Outcome: one runs, one exits cleanly

### Both modes failed (e.g., network outage hit both)
- Tomorrow's run sees yesterday's `status: failed` for both
- No skip — both proceed normally
- The failed brief from yesterday is lost; carry-over patches (in state.json) survive

### Cloud has no Drive access (rare — depends on user's cloud MCP setup)
- Cloud falls back to "coord-via-prompt" — embedded in the prompt text it pastes back to the agent
- This is degraded mode; user warned in setup

### Wallclock drift (modes' clocks differ by >5 min)
- Heartbeats are UTC ISO, monotonic when correct
- Drift > 5 min triggers a "WARN: coord heartbeats look drifted" log entry
- No automatic recovery — user notified

---

## Anti-recommendations (don't do these)

1. ❌ Don't use a flat file in user's project as coord store. It's a separate domain.
2. ❌ Don't rely on filesystem-only coord (local and cloud have different filesystems).
3. ❌ Don't put coord state in `state.json` — that's per-run carryover, not concurrency-safe.
4. ❌ Don't use raw start time for crash detection — heartbeats only. Some legit steps take 25+ min.
