# Night Shift Agent

> An autonomous AI agent that does your work while you sleep — installed via a conversational wizard, fully self-contained, runs on your machine.

**Status:** Under active development.

## What this is

You have Claude Code on your machine. You point this installer at your project; it interviews you for ~20-30 minutes about what you want done, what tools you use, and how much autonomy you trust it with. Then it builds — locally, on your disk — a personalized agent that fires every night, picks up your unfinished work, generates patches, writes a morning brief, and stays out of your way.

See [`examples/sample-brief.md`](examples/sample-brief.md) for what the morning deliverable looks like.

It is **not** a SaaS. There is no remote server you depend on, no account to create, no usage-metered cloud. The whole agent lives in `~/night-shift-agent/` (or wherever you tell it to), wired to your local Claude Code, and runs via your operating system's scheduler.

## Why bother

The hard part of running an LLM agent overnight isn't the LLM — it's the infrastructure. Lockfiles. Heartbeats. Stall watchdogs. Cleanup traps. PATH gotchas under `launchd`. Credential scrubbing in logs. Network recovery if wifi drops. Caffeinate so the Mac doesn't sleep mid-run. Snapshot/restore so the agent doesn't corrupt your working tree. Retry loops that respect rate limits. Permission sandboxes so it can't `rm -rf $HOME`.

These eat days of debugging in production. This installer bakes in battle-tested patterns from a real working night-shift system and asks you the right configuration questions to wire them to *your* setup — your stack, your tools, your project, your risk tolerance.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/adriankrawczyk/night-shift-agent/main/install.sh | bash
```

That clones the installer to `~/.night-shift-installer/`, runs preflight (`git`/`jq`/`claude`), and launches the wizard in your Claude Code session. Pick a setup depth (Minimal / Full), answer the questions, and let it generate the agent.

Prefer to inspect first?

```bash
git clone https://github.com/adriankrawczyk/night-shift-agent ~/.night-shift-installer
bash ~/.night-shift-installer/install.sh           # launches wizard
bash ~/.night-shift-installer/install.sh --no-launch   # just clone, paste prompt manually
bash ~/.night-shift-installer/install.sh --update      # pull latest and re-launch
```

The wizard takes ~20-30 min for the Full tier. You can kill it at any time and re-run — it detects in-progress state at `~/.config/night-shift-agent/wizard-state/` and offers to resume.

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

By tier, total question count: **Minimal ~15**, **Full ~34** (skip-on-default + conditional gates reduce what you actually answer — Full averages ~20-25 in practice).

## Platform support

**macOS only.** The installer uses launchd, caffeinate, networksetup, plutil, osascript, and SwiftBar — all macOS-specific. Linux/Windows are not supported.

## Cost

The night agent runs against your **Claude Code** install — so the model billing is whatever your Claude plan covers.

- **Claude Pro / Max plan** (recommended): nightly runs use your existing subscription. Effective marginal cost: $0.
- **Anthropic API direct** (if you use Claude Code with a raw API key): a Full-tier setup with daily-meta + nightly + meta-agent fires ~3 long sessions/day. Heavy nights (300-min hard wall, many patches) can run 200k-1M output tokens per night. Rough order of magnitude with Sonnet pricing: **$3-15/day**, $90-450/month. With Haiku for subagents you can cut this significantly. There is no published estimate — measure with `claude --print --max-budget-usd N` locally for a few nights to calibrate.

The wizard's Q7.3 (hard wall) is the main cost knob. Minimal tier defaults to a 60-min wall; Full tier to 300 min.

## Architecture

```
night-shift-agent/                   ← installer (this repo)
├── INSTALL.md                       ← short paste-into-Claude bootstrap
├── META_PROMPT.md                   ← the wizard engine (core principles, startup, variables schema, scan edges)
├── phases/                          ← per-phase logic (phase-0..phase-10.md), loaded on demand
├── wizard-questions.yaml            ← question data (edit this to change Qs)
├── BASH_PATTERNS.md                 ← 18 universal bash patterns (P1..P18), pulled by templates at render time
├── MCP_PATTERNS.md                  ← universal MCP install procedure + recipes for top 10 MCPs
├── PERSONA_BUILDER.md               ← reviewer-style.md generation algorithm (concrete steps)
├── COORD_PATTERN.md                 ← multi-machine (local + cloud) coord protocol
├── README.md                        ← this file
├── templates/                       ← 28 scaffolds the wizard renders into your install
│   ├── README.md                    ← template grammar + variables contract
│   ├── prompt.md.template
│   ├── run.sh.template
│   ├── settings.json.template
│   ├── launchd-routine.plist.template
│   ├── subagent-{coder,reviewer,tester,triager}.md.template
│   ├── daily-meta.{sh,plist,prompt.md}.template
│   ├── meta-agent.sh.template / meta-prompt.md.template
│   └── …
└── recipes/                         ← work-recipe definitions (YAML, one per recipe)
    ├── pr-responder.yaml
    ├── bug-triager.yaml
    ├── code-health-check.yaml
    ├── draft-pr-finisher.yaml
    ├── maintenance-bot.yaml
    └── preempt-review.yaml

~/night-shift-agent/                 ← what the wizard generates for you
├── prompt.md                        ← agent brain (your personalized version)
├── run.sh                           ← wrapper script (with 18 bash patterns inlined)
├── settings.json                    ← permissions + deny list
├── .claude/agents/                  ← coder/reviewer/tester/triager/convention-checker (per your config)
├── recipes/                         ← copies of the recipes you picked
├── reviewer-style.md                ← (if persona enabled) generated from real PR scans
├── meta-prompt.md                   ← (if meta-agent enabled) self-improvement loop
├── runs/                            ← logs, jsonl events, briefs per date
├── patches/                         ← generated patches per date
├── checkpoints/                     ← user-repo snapshots (rollback safety)
└── README.md                        ← user-facing operational reference
```

## Editing questions post-install

The wizard's question list lives in `~/.night-shift-installer/wizard-questions.yaml` — structured, ID'd, tier-tagged. Want a different wording? Edit the file. Want to add a question? Add an entry. Re-run the wizard and it picks up your edits. The engine (META_PROMPT.md) is question-agnostic.

## Verifying integrity (contributors only)

`tests/` and `validate.sh` are dev tooling — they live in the repo so contributors can verify their changes, but the wizard never copies them to your install. As an installing user you can ignore them.

If you ARE editing the installer (templates, schema, BASH_PATTERNS), run:

```bash
bash validate.sh
```

It checks repo layout, question-ID consistency, bash-pattern extraction, wizard-questions schema, recipe-YAML schema, depends_on cross-resolution (catches silent-skip bugs where a question references a derived var that no phase computes), recipe-trigger cross-resolution against phase-1's evaluator catalog (catches "trigger never fires so recipe never appears in picker"), template-var cross-resolution against META_PROMPT.md schema (catches "template uses var X but META_PROMPT doesn't define it → renders as empty string at install"), then renders every template against two mock contexts (minimal / full) verifying zero unresolved `{{ variables }}` plus `bash -n`, `plutil -lint`, `jq empty`, shellcheck, and golden-file regression on security-critical surfaces. 85 assertions; takes <5 seconds. Use in CI or before sharing changes.

## License

MIT.
