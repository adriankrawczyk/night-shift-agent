# 🌙 Night Shift Agent

> An autonomous AI agent that does your work while you sleep.

**Status:** under active development · **macOS only**

## What it is

You point this installer at your project. It interviews you (~20–30 min) about
what to do, which tools you use, and how much autonomy you trust it with — then
builds, **locally on your disk**, an agent that fires every night, picks up your
unfinished work, generates patches, and writes a morning brief.

Not a SaaS. No server, no account, no cloud metering. Lives in `~/night-shift-agent/`,
wired to your local Claude Code, run by launchd.

The hard part of an overnight agent isn't the LLM — it's the infrastructure:
lockfiles, stall watchdogs, caffeinate, credential scrubbing, snapshot/restore,
rate-limit retries, a sandbox that can't `rm -rf $HOME`. This bakes in
battle-tested patterns from a real working night-shift system.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/adriankrawczyk/night-shift-agent/main/install.sh | bash
```

Clones to `~/.night-shift-installer/`, runs preflight (`git`/`jq`/`claude`), launches
the wizard. Pick a tier (Minimal / Full), answer, done. Kill & re-run anytime — it resumes.

## What the wizard asks

| Phase | Figures out |
|---|---|
| 0 · Preflight | Project path, stack, what's already connected |
| 1 · What to do | Your goal + matching work-recipes |
| 2 · Services | Which MCPs / data sources to use |
| 3 · Reviewer persona | *(opt)* learn your reviewer's style |
| 4 · Output | Where the brief lands (file / email / Slack) |
| 5 · Verify loop | How patches are checked before shipping |
| 6 · Delivery | Patches on disk vs PRs vs auto-merge |
| 7 · Schedule + resilience | When it runs, how hard it recovers |
| 8 · Meta-agent | *(opt)* a second agent that grades & improves the first |
| 9 · Dashboard | *(opt)* menu-bar status widget |
| 10 · Commit | Preview, test fire, push |

**Minimal ≈ 15 questions · Full ≈ 34** (defaults + conditional gates → you answer ~20–25).

## Cost

Runs against your **Claude Code** install. On a Pro/Max plan: ~$0 marginal.
On raw API: roughly **$3–15/night** at Full tier (Q7.3 hard-wall is the main knob).

## License

MIT.
