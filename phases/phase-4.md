## PHASE 4 — Output channels

### Q4.1 — Channel multi-select

**Tier handling: Minimal uses scan-driven smart default — no question shown.**

Pick the best already-available channel based on `$SCAN_JSON.existing_mcps`, in priority order:

1. If `slack` MCP connected → default = `["slack_dm"]` (DM to self — agent reads `slack_search_users` to find user's own id at first run)
2. Else if `gmail` MCP connected → default = `["email"]` (recipient = `git config user.email`)
3. Else if `drive` MCP connected → default = `["drive_doc"]` (folder = root or `night-shift-briefs/` if exists)
4. Else → default = `["macos_notification", "markdown"]` — fires a macOS banner via `osascript -e 'display notification ...'` AND drops markdown to `<install>/runs/<date>/brief.md`. Banner says "Night shift brief ready: N patches, M reviews — open with `night-shift brief`". Clicking the banner triggers `open <path>` via terminal-notifier if installed; otherwise the CLI command is the access path.

After picking the silent default, PRINT to user:
> "I'll deliver my morning brief via {{ chosen_channel_label }} — using your already-connected {{ underlying_service }}. Change later with `night-shift extend output <channel>`. You can also run `night-shift brief` anytime to open the latest one."

**The `night-shift brief` CLI command** (defined in `templates/cli.template`) opens the most recent brief in `$EDITOR` or via `open` — this is the universal fallback access path regardless of delivery channel.

If `tier == full`, ask the question.

Build options from:
- Always: markdown file in install folder, GitHub issue (if `.gh_repo.create`)
- Detected: any connected MCP with write capabilities (Gmail, Slack, Drive, Notion, Discord, etc.)
- Always: custom webhook URL
- For services not connected but available in mcp-registry — show as "could install if you want this channel" with name pulled from registry

Multi-select. At least one required. Persist as `.output_channels = ["markdown", "email", "slack_dm"]`.

**If the user picks a channel whose service is NOT yet installed (e.g., they pick "email" but Gmail MCP isn't installed):**

LOOP BACK INTO PHASE 2 INSTALL FLOW INLINE before continuing Q4.2:

```
For each picked channel where the underlying service is not in $existing_mcps:
  1. Show user: "Email needs the Gmail MCP. I'll install it now — same one-shot flow as Phase 2.2."
  2. Execute the Q2.2 install procedure (see MCP_PATTERNS.md)
  3. On success: append the new MCP to $existing_mcps in $SCAN_JSON
  4. On failure: warn user, ask "do you want to fall back to another channel for this brief, or skip the brief from this channel?"
  5. Continue to Q4.2 with updated state
```

This is the same install flow as Phase 2 — just triggered later. Don't fork a separate install procedure; reuse MCP_PATTERNS.md universal install.

### Q4.2 — Per-channel detail (loop, tier-gated)

For each picked channel, ask only meaningful detail:

| Channel | Detail |
|---|---|
| markdown | none (auto-path: `<install>/runs/<date>/brief.md`) |
| macos_notification | none (auto: `osascript -e 'display notification "..." with title "Night Shift" subtitle "..."'`; needs no MCP, macOS-only) |
| email | recipient (default git user.email), subject prefix |
| slack_dm | target user (autocomplete from MCP) |
| slack_channel | channel (autocomplete) |
| drive_doc | drive folder (autocomplete) |
| github_issue | repo + labels + auto-close days |
| notion | parent page (autocomplete) |
| discord | channel/DM (autocomplete) |
| webhook | URL + auth header pattern |

Persist as `.output_channels_detail = {...}`.

### Q4.3 — Brief length
Lean / Medium / Deep. Persist `.brief_length`. Applies uniformly to all chosen channels.

---

