# Templates

Files in this directory are rendered by the wizard at install time. Variables come from `$ANSWERS_JSON` + `$SCAN_JSON`. Bash patterns come from `../BASH_PATTERNS.md` (referenced as `{{ pattern.<id> }}`).

## Template syntax

```
{{ key }}                              — interpolate scalar value
{{ deeply.nested.key }}                — interpolate nested
{{#if condition }}...{{/if}}           — conditional block
{{#unless condition }}...{{/unless}}   — inverse conditional
{{#each list }}...{{/each}}            — iterate list (use {{ this }} or {{ this.field }} inside)
{{ pattern.P1 }}                       — render bash pattern from BASH_PATTERNS.md
```

## Files

| Template | Renders to | Conditions |
|---|---|---|
| `prompt.md.template` | `<install>/prompt.md` | always |
| `run.sh.template` | `<install>/run.sh` | always |
| `settings.json.template` | `<install>/settings.json` | always |
| `launchd-routine.plist.template` | `~/Library/LaunchAgents/com.<user>.night-shift-routine.plist` | if execution_mode in [local, both] AND os==macOS |
| `protect-user-state.sh.template` | `<install>/protect-user-state.sh` | always |
| `triage.sh.template` | `<install>/triage.sh` | always |
| `predictive-skip.sh.template` | `<install>/predictive-skip.sh` | if scheduling on |
| `cli.template` | `<install>/cli/night-shift` | always |
| `subagent-coder.md.template` | `<install>/subagents/coder.md` | always |
| `subagent-reviewer.md.template` | `<install>/subagents/reviewer.md` | if reviewer_persona.enabled |
| `subagent-tester.md.template` | `<install>/subagents/tester.md` | if Q5.2 enabled |
| `subagent-triager.md.template` | `<install>/subagents/triager.md` | if "bug_triager" in recipes |
| `meta-agent.sh.template` | `<install>/meta-agent.sh` | if meta_agent != off |
| `meta-prompt.md.template` | `<install>/meta-prompt.md` | if meta_agent != off |
| `swiftbar.sh.template` | `<install>/dashboard/swiftbar.sh` | if dashboard == yes |
| `notify-watcher.sh.template` | `<install>/dashboard/notify-watcher.sh` | if dashboard == yes |
| `dashboard-notifier.plist.template` | `~/Library/LaunchAgents/com.<user>.night-shift-dashboard-notifier.plist` | if dashboard == yes |
| `gitignore.template` | `<install>/.gitignore` | always |
| `readme-user.md.template` | `<install>/README.md` | always (user-facing install README) |

## Generation order

1. Create install dir
2. Render every "always" template
3. Render conditional templates per their conditions
4. Generate non-templated files (e.g., reviewer-style.md is built from actual PR scans)
5. chmod +x bash scripts
6. chmod 600 secrets file (if any)
7. Install plists (launchctl bootstrap)
8. Create GH repo if requested
