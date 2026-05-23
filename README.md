# Night Shift Agent

> An autonomous AI agent that does your work while you sleep — installed via a conversational wizard, fully self-contained, runs on your machine.

**Status:** v0.1 — under active development.

## What this is

You have Claude Code on your machine. You point this installer at your project; it interviews you for ~20-30 minutes about what you want done, what tools you use, and how much autonomy you trust it with. Then it builds — locally, on your disk — a personalized agent that fires every night, picks up your unfinished work, generates patches, writes a morning brief, and stays out of your way.

It is **not** a SaaS. There is no remote server you depend on, no account to create, no usage-metered cloud. The whole agent lives in `~/night-shift-agent/` (or wherever you tell it to), wired to your local Claude Code, and runs via your operating system's scheduler.

## Why bother

The hard part of running an LLM agent overnight isn't the LLM — it's the infrastructure. Lockfiles. Heartbeats. Stall watchdogs. Cleanup traps. PATH gotchas under `launchd`. Credential scrubbing in logs. Network recovery if wifi drops. Caffeinate so the Mac doesn't sleep mid-run. Snapshot/restore so the agent doesn't corrupt your working tree. Retry loops that respect rate limits. Permission sandboxes so it can't `rm -rf $HOME`.

These eat days of debugging in production. This installer bakes in patterns from a real working system (`~/reference-setup`, in daily use since early 2026) and asks you the right configuration questions to wire them to *your* setup — your stack, your tools, your project, your risk tolerance.

## Quick start

```bash
git clone https://github.com/<your-handle>/night-shift-agent ~/.night-shift-installer
cd ~/.night-shift-installer
```

Then open Claude Code in any directory and paste:

```
Read /Users/<you>/.night-shift-installer/META_PROMPT.md and run the wizard.
```

The wizard takes over from there. Pick a setup depth (Minimal / Balanced / Full), answer the questions it asks, watch it scan your project + connected MCPs, and let it generate the agent for you.

## What the wizard asks (10 phases)

| Phase | Topic | What it figures out |
|---|---|---|
| 0 | Preflight | Where's your project, what's your stack, what's already connected |
| 1 | What to do | Free-form goal + scan-driven recipe picks |
| 2 | Services & inputs | Which MCPs to install/use, what data sources to read |
| 3 | Reviewer persona | Optional: learn the style of whoever reviews your PRs |
| 4 | Output channels | Where the morning brief lands (file / email / Slack / etc.) |
| 5 | Verify loop | How the agent checks its patches before shipping them |
| 6 | Patch delivery | Patches on disk vs PRs vs auto-merge |
| 7 | Schedule + resilience | When the agent runs, how hard it tries to recover from errors |
| 8 | Meta-agent | Optional: a second agent that grades runs and improves the first |
| 9 | Dashboard | Optional: menu-bar widget showing agent status |
| 10 | Dry-run + commit | Preview, test fire, push to GitHub |

By tier, total question count: **Minimal ~10**, **Balanced ~25**, **Full ~40**.

## Platform support

- **macOS** — full support (launchd, caffeinate, networksetup wifi recovery, SwiftBar dashboard)
- **Linux** — planned for v0.2 (systemd, nmcli, notify-send, journalctl)
- **Windows** — under consideration

## Architecture

```
night-shift-agent/                   ← installer (this repo)
├── META_PROMPT.md                   ← the wizard — Claude Code reads this
├── wizard-questions.yaml            ← question data (edit this to change Qs)
├── templates/                       ← scaffolds the wizard renders into your install
│   ├── prompt.md.template
│   ├── run.sh.template
│   ├── settings.json.template
│   ├── launchd-routine.plist.template
│   ├── subagent-coder.md.template
│   └── …
├── recipes/                         ← work-recipe definitions
│   ├── pr-responder.yaml
│   ├── bug-triager.yaml
│   ├── code-health-check.yaml
│   └── …
├── lib/                             ← shared bash helpers
│   ├── lock.sh
│   ├── heartbeat.sh
│   ├── watchdog.sh
│   ├── network-recovery.sh
│   └── …
└── INSTALL.md                       ← short paste-into-Claude bootstrap (alt to META_PROMPT)

~/night-shift-agent/                 ← what the wizard generates for you
├── prompt.md
├── run.sh
├── settings.json
├── subagents/
├── recipes/
├── runs/
├── patches/
└── …
```

## Editing questions post-install

The wizard's question list lives in `~/.night-shift-installer/wizard-questions.yaml` — structured, ID'd, tier-tagged. Want a different wording? Edit the file. Want to add a question? Add an entry. Re-run the wizard and it picks up your edits. The engine (META_PROMPT.md) is question-agnostic.

## Credits & lineage

Built on patterns from [adriankrawczyk's `reference-setup`](https://github.com/adriankrawczyk/night-shift-agent) — a working night-shift agent in daily use since 2026.

Reviewer-persona idea + tactical/architectural meta-agent taxonomy + bash gotchas catalog — all from that system, generalized.

## License

MIT.
