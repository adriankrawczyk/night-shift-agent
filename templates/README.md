# Templates

Files in this directory are rendered by the wizard at install time. Variables come from `$ANSWERS_JSON` + `$SCAN_JSON`. Bash patterns come from `../BASH_PATTERNS.md` (referenced as `{{ pattern.<id> }}`).

## Template syntax

Basic:
```
{{ key }}                              — interpolate scalar value
{{ deeply.nested.key }}                — interpolate nested
{{#if condition }}...{{/if}}           — conditional block
{{#if condition }}...{{else}}...{{/if}} — conditional with else
{{#unless condition }}...{{/unless}}   — inverse conditional
{{#each list }}...{{/each}}            — iterate list (use {{ this }} or {{ this.field }} inside)
{{ @index }}                           — current index inside {{#each}} (0-based)
{{ ../foo }}                           — climb one frame up inside nested {{#each}}
{{ pattern.P1 }}                       — render bash pattern from BASH_PATTERNS.md (P1..P18)
```

Extended (used by current templates; render engine MUST support):
```
{{#if (eq this "markdown") }}          — subexpression: eq compares scalar literals
{{#if (eq ui_automation_tool "argent")}}  — same, applied to a non-`this` var

{{ X * 0.6 | round }}                  — inline arithmetic + filter (round/floor/ceil)
                                          Implementation: evaluate expression, apply filter at render time.
                                          Used only by prompt.md.template for LEAN_MODE threshold.

{{> (lookup recipe_gather_steps this) }}  — partial inclusion via map lookup
                                          Resolve: read recipe_gather_steps[this], read that file path
                                          relative to $INSTALLER_DIR, render it with the current render-context,
                                          inline result at this location.

{{#if recipe_includes "bug_triager"}}  — helper: `recipe_includes` evaluates `"bug_triager" ∈ recipes`
                                          Other helpers used:
                                          - `eq A B` → A == B as strings
                                          - `recipe_includes "id"` → id ∈ recipes array
```

When rendering a template the engine MUST:
1. Resolve every `{{ x }}` to a value (string, number, bool, or array)
2. Evaluate boolean blocks (`{{#if}}` etc.) and skip/include their bodies accordingly
3. Iterate `{{#each list}}` bodies — push `this`, `@index`, and parent context for `../`
4. Recursively render partials inlined via `{{> name }}`
5. Apply inline filters (`| round`) after expression evaluation
6. Treat unresolved variables as render errors — do not silently emit `{{ ... }}` literally to the output

See `../META_PROMPT.md` § "VARIABLES SCHEMA" for the complete contract of which variables every template references and where they come from.

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
