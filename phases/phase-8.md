## PHASE 8 — Meta-agent

**Skipped entirely if `.gh_repo.create = false`.**

### Q8.1 — Opt-in (only if GH repo)
Standard. Persist `.meta_agent = "auto_merge_safe|draft_only|off"`.

### Q8.2 — Pre-night signal analyzer (daily-meta) — Full tier only (GAP #20 fix)

Standard. Persist `.daily_meta = bool`.

Question wording:
> Want a pre-night signal analyzer that reads your day's activity (Claude Code sessions, Slack DMs, GitHub PRs, Linear updates) at evening time and produces a report your night-agent reads at midnight? Gives me extra context to prioritize.

If yes:
- Wizard generates `daily-meta.sh.template` + `daily-meta-prompt.md.template` + `daily-meta.plist.template` (separate launchd plist, fires ~2h before main routine).
- Daily-meta writes to `<install>/daily-meta/<date>.md` which the main agent's prompt reads at STEP 0.

---

