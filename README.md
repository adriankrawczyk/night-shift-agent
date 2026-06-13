# 🌙 Night Shift Agent

> An autonomous AI agent that does your work while you sleep.

**Status:** under active development · **macOS only**

## What it is

It is basically a huge prompt that is read by your Claude Code that handles all configuration for you.
It interviews you (~20–30 min) about what to do, which tools you use, and how much autonomy you trust it with — then
builds, **locally on your disk**, an agent that fires every night, picks up your work, generates patches, and writes a morning brief.

The hard part of an overnight agent isn't the AI — it's everything around it. It keeps your Mac from falling asleep mid-task. It makes a backup before touching anything, so a bad run rolls back instead of corrupting your files. It never runs two copies on top of each other. If it gets stuck, it notices and recovers instead of hanging until morning. When the wifi drops or the API says "slow down," it waits and retries instead of giving up. It keeps your passwords and API keys out of the logs. And it works in it's sandbox in so it can't wipe your files even if something goes wrong.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/adriankrawczyk/night-shift-agent/main/install.sh | bash
```

Clones to `~/.night-shift-installer/` and launches
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

**Minimal ≈ 15 questions · Full ≈ 34**

## License

MIT.
