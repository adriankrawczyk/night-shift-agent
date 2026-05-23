# Night Shift Agent — Manual Install (paste into Claude Code)

The fast path is `bash install.sh` from the repo root (see [README](README.md)). This file is for the manual flow when that's not an option.

## Step 1 — clone

```bash
git clone https://github.com/adriankrawczyk/night-shift-agent ~/.night-shift-installer
```

## Step 2 — paste into Claude Code (any directory)

> Read `~/.night-shift-installer/META_PROMPT.md` and run the Night Shift Agent installer wizard. The installer is at `~/.night-shift-installer`.

That's it. The wizard takes over from there — META_PROMPT.md contains the full startup sequence, all 10 phases, the variables schema, and the file-generation logic.

## Troubleshooting

**"File not found"** — installer didn't clone to the expected path. Locate it:
```bash
find ~ -maxdepth 3 -name META_PROMPT.md 2>/dev/null
```

**"jq not found"** — `brew install jq` (mac) or `sudo apt install jq` (linux).

**"claude not found"** — install Claude Code: https://docs.claude.com/en/docs/claude-code/quickstart

**Wizard exited mid-flow** — re-paste the same prompt. The wizard detects in-progress state at `/tmp/night-shift-wizard/` and offers resume.
