## PHASE 10 — Dry-run + commit

### Q10.1 — Preview + change loop

Generate a summary from `$ANSWERS_JSON`:

```
Here's what I'll create:

In <install_dir>/:
  - prompt.md (your customized brain)
  - run.sh (runner script)
  - settings.json (permissions)
  - launchd-routine.plist (schedule)
  - .claude/agents/coder.md (helper persona — Claude Code's subagent discovery convention)
  - <list each file>

Plus:
  - GitHub repo: <owner/name> (<visibility>)
  - Encrypted secrets at ~/.config/night-shift-agent/secrets.json

Total: <N> files.

Cost estimate:
  - Schedule: {{ schedule_human_readable }}, hard wall {{ hard_wall_minutes }} min
  - Token usage per night: rough order of magnitude
      * Minimal (60-min wall, no meta-agent, no daily-meta): ~50-200k output tokens
      * Balanced (180-min wall, meta-agent draft_only): ~200-500k output tokens
      * Full (300-min wall + meta-agent + daily-meta): ~400k-1M output tokens
  - Billed to your Claude plan (Pro/Max absorbs it; raw API ~$3-15/day at Sonnet pricing).
  - You can reduce cost later by lowering hard_wall_minutes or disabling meta-agent.
```

Ask: change anything?
- A: create
- B: free text changes (then iterate — apply changes to $ANSWERS_JSON, re-show summary)
- C: cancel

### File generation (when A picked)

For each template in `templates/`, read it, fill placeholders from `$ANSWERS_JSON` + `$SCAN_JSON`, write to install location.

Placeholders use `{{ key }}` syntax. Conditionals use `{{#if key}}...{{/if}}`. Loops use `{{#each list}}...{{/each}}`.

See `templates/README.md` for the full template grammar.

**REQUIRED pre-render derivation step** (must run BEFORE iterating templates):

For each `recipe_id` in `$ANSWERS_JSON.recipes`, read `$INSTALLER_DIR/recipes/<recipe_id>.yaml` and pluck `gather_steps.{description, bash_pattern}` into a flat map keyed by recipe id. Render-context field name: `recipe_gather_steps`.

```bash
# Pseudocode (real impl uses jq + yq if installed, or Python yaml parser otherwise):
RECIPE_GATHER_STEPS_JSON='{}'
for recipe_id in $(jq -r '.recipes[]' "$ANSWERS_JSON"); do
  recipe_yaml="$INSTALLER_DIR/recipes/${recipe_id}.yaml"
  [ -f "$recipe_yaml" ] || continue
  description=$(yq -r '.gather_steps.description' "$recipe_yaml")
  bash_pattern=$(yq -r '.gather_steps.bash_pattern' "$recipe_yaml")
  RECIPE_GATHER_STEPS_JSON=$(echo "$RECIPE_GATHER_STEPS_JSON" \
    | jq --arg id "$recipe_id" --arg gs "### Gather: $description\n\n\`\`\`bash\n$bash_pattern\n\`\`\`\n" \
        '. + {($id): $gs}')
done
# Inject as recipe_gather_steps in render context for {{ recipe_gather_steps.<id> }}.
```

Skipping this step leaves `{{ recipe_gather_steps.pr_responder }}` etc. unresolved → renders as `<<partial-missing>>` markers in `prompt.md`.

**Generated files by category:**

| File | Template | Conditions |
|---|---|---|
| `<install>/prompt.md` | `prompt.md.template` | always |
| `<install>/run.sh` | `run.sh.template` | always |
| `<install>/settings.json` | `settings.json.template` | always |
| `<install>/recipes/<id>.yaml` | (copied verbatim from `$INSTALLER_DIR/recipes/<id>.yaml`) | per picked recipe |
| `<install>/.claude/agents/coder.md` | `subagent-coder.md.template` | always |
| `<install>/.claude/agents/reviewer.md` | `subagent-reviewer.md.template` | if `reviewer_persona_enabled` AND `len(reviewer_persona_handle) > 0` (skip rendering when persona was enabled but PERSONA_BUILDER produced no usable handle — e.g. bot-only handles, network failure — to avoid `Read .../reviewer-style.md` failing at first action) |
| `<install>/.claude/agents/tester.md` | `subagent-tester.md.template` | if ui_automation_enabled |
| `<install>/.claude/agents/triager.md` | `subagent-triager.md.template` | if "bug_triager" in recipes |
| `<install>/.claude/agents/convention-checker.md` | `subagent-convention-checker.md.template` | if `convention_checker_enabled` (true when scan detects `.cursor/rules/`, `.eslintrc*`, `eslint.config.*`, `biome.json`, `.prettierrc*`, `prettier.config.*`, or `.editorconfig` in any user project) |

**WHY `.claude/agents/` not `subagents/`:** Claude Code's subagent discovery walks up from the current working directory looking for `.claude/agents/<name>.md` files (per docs at https://code.claude.com/docs/en/subagents.md). A directory called `subagents/` is NOT discovered. The night agent runs with `cwd={{ install_dir }}`, so subagents at `{{ install_dir }}/.claude/agents/<name>.md` are found via that walk-up. If you generate them anywhere else, `Agent(subagent_type="coder")` will silently fail to find them and fall back to the general-purpose agent.
| `<install>/reviewer-style.md` | (generated, not templated — built via `PERSONA_BUILDER.md`) | if reviewer_persona_enabled |
| `<install>/protect-user-state.sh` | `protect-user-state.sh.template` | always |
| `<install>/predictive-skip.sh` | `predictive-skip.sh.template` | if execution_mode != on_demand |
| `~/Library/LaunchAgents/com.<user_short>.night-shift-predictive-skip.plist` | `predictive-skip.plist.template` | if execution_mode != on_demand AND macOS |
| `<install>/daily-meta.sh` | `daily-meta.sh.template` | if daily_meta == true (Q8.2 Full tier) |
| `<install>/daily-meta-prompt.md` | `daily-meta-prompt.md.template` | if daily_meta == true |
| `~/Library/LaunchAgents/com.<user_short>.night-shift-daily-meta.plist` | `daily-meta.plist.template` | if daily_meta == true AND macOS |
| `<install>/triage.sh` | `triage.sh.template` | always (CLI helper) |
| `<install>/cli/night-shift` | `cli.template` | always (apply patches command) |
| `<install>/meta-agent.sh` | `meta-agent.sh.template` | if meta_agent_enabled |
| `<install>/meta-prompt.md` | `meta-prompt.md.template` | if meta_agent_enabled |
| `<install>/META-DECISIONS.md` | `META-DECISIONS.md.template` | if meta_agent_enabled |
| `~/Library/LaunchAgents/com.<user_short>.night-shift-routine.plist` | `launchd-routine.plist.template` | if execution_mode in [local, both] AND macOS |
| `<install>/dashboard/swiftbar.sh` | `swiftbar.sh.template` | if dashboard.enabled AND macOS |
| `<install>/dashboard/notify-watcher.sh` | `notify-watcher.sh.template` | if dashboard.enabled AND macOS |
| `<install>/dashboard/actions/copy-apply.sh` | `dashboard-action-copy-apply.sh.template` | if dashboard.enabled AND macOS |
| `<install>/dashboard/actions/run-night.sh` | `dashboard-action-run-night.sh.template` | if dashboard.enabled AND macOS |
| `<install>/dashboard/actions/tail-log.sh` | `dashboard-action-tail-log.sh.template` | if dashboard.enabled AND macOS |
| `~/Library/LaunchAgents/com.<user_short>.night-shift-dashboard-notifier.plist` | `dashboard-notifier.plist.template` | if dashboard.enabled AND macOS |
| `<install>/.gitignore` | `gitignore.template` | always |
| `<install>/README.md` | `readme-user.md.template` | always (user-facing) |
| `~/.config/night-shift-agent/secrets.json` | (generated from Q5.3 answers) | if any secrets |
| `<install>/wizard-questions.yaml` | (copy of installer's yaml — for post-install edits) | always |

After file generation:
- `chmod +x <install>/run.sh <install>/*.sh <install>/cli/night-shift <install>/dashboard/*.sh <install>/dashboard/actions/*.sh`
- `chmod 600 ~/.config/night-shift-agent/secrets.json` (if exists)
- Ensure `<install>/.claude/agents/` exists (mkdir -p) before writing subagent files
- Init git repo at `<install>` if `.gh_repo.create`
- Run `launchctl bootstrap gui/$(id -u)/ <each plist>` for every plist written under `~/Library/LaunchAgents/`

### Q10.2 — Test run

If user picks A: run `<install>/run.sh --dry-run` and stream output. Report exit code. If failed, surface error verbatim.

### Q10.3 — Push to GitHub

If user picks A and `.gh_repo.create`:
```bash
cd "$INSTALL_DIR"
gh repo create "$REPO_NAME" --"$VISIBILITY" --source=. --push
```

### Final summary (always, after all of the above)

Print a single concise block — this is the LAST thing the user sees before the wizard exits. Don't bloat it; format as actionable next steps:

```
✓ Night Shift Agent installed.

Where things are:
  Install dir: {{ install_dir }}
  User-facing README: {{ install_dir }}/README.md
  Generated CLI: {{ install_dir }}/cli/night-shift

First scheduled run: {{ schedule_human_readable }} ({{ first_run_iso }} local).
{{#if multi_machine}}
  Note: also configure the cloud half via {{ install_dir }}/coord.md.
{{/if}}

Try these now:
  {{ install_dir }}/cli/night-shift doctor         # health-check the install
  {{ install_dir }}/cli/night-shift run --dry-run  # exercise without shipping artifacts
  {{ install_dir }}/cli/night-shift logs           # tail latest run log

To edit later:
  - Questions / scan answers: re-run `bash {{ installer_dir }}/install.sh --update` and pick "B: edit"
  - Templates / patterns: edit files under {{ installer_dir }}/templates/ then re-run wizard
  - Schedule: launchctl unload + edit ~/Library/LaunchAgents/com.{{ user_short }}.night-shift-routine.plist + load

If anything breaks: `{{ install_dir }}/cli/night-shift doctor` first, then check
{{ install_dir }}/runs/launchd.stdout.log for the most recent failure.
```

Compute `first_run_iso` from `$ANSWERS_JSON.schedule` — next matching weekday + time after `now()`.

---

