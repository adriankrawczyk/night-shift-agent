## PHASE 1 — What should I do?

### Q1.1 — Free-form goal
Plain text prompt. Read user's response, save to `$ANSWERS_JSON` as `q1_1`. No parsing yet — used as context for Q1.2 recipe matching.

### Q1.2 — Scan-driven recipe picks

Load recipes from `$INSTALLER_DIR/recipes/*.yaml`. The recipe schema (every YAML file in `recipes/` conforms):

```yaml
id: <snake_case_id>           # unique, also used in $ANSWERS_JSON.recipes array
name: "<human title>"         # shown in Q1.2 picker
description: "<one paragraph>" # shown in Q1.2 picker
triggers:                      # list — Phase 1 evaluates against $SCAN_JSON
  - has_open_prs_with_reviews
  - user_mentioned:review
required_services:             # MCPs the recipe NEEDS (cannot run without)
  - github
helpful_services:              # MCPs that enrich the recipe (optional)
  - slack
  - linear
default_settings:              # recipe-specific knobs the wizard exposes (Full tier only via Q2.3-style)
  iterate_per_pr: true
  max_pr_per_run: 8
gather_steps:                  # used by prompt.md.template's STEP 2 GATHER
  description: |
    <markdown — how the night agent should pull data for this recipe>
  bash_pattern: |
    <bash example the agent can run>
implementation_pattern:        # documentation, not directly templated — the agent reads this at run time
  description: |
    <markdown — how to convert gathered data into a patch>
  brief_section: |
    <markdown — what to put in the morning brief for this recipe>
  reviewer_persona_relevance: HIGH|MEDIUM|LOW
  argent_relevance: HIGH|MEDIUM|LOW
failure_modes:                 # documentation — known edge cases
  - "<one-line situation>": <one-line handling rule>
```

When the wizard runs Q1.2, it only reads `id` / `name` / `description` / `triggers` / `required_services` / `helpful_services` for the picker UI. The rest is read by the rendered agent at run time via `<install>/recipes/<id>.yaml` (the wizard copies the picked recipe files verbatim).

For each recipe, evaluate its `triggers` against `$SCAN_JSON`:

**`has_*` triggers (scan-derived) — full catalog:**
- `has_open_prs_with_reviews` → `.projects[].user_open_prs[].reviews | length > 0`
- `has_open_non_draft_prs_without_recent_reviews` → `.projects[].user_open_prs[] | select(.isDraft == false) | select(.reviews | length == 0 or (.reviews | sort_by(.submittedAt) | last.submittedAt < .updatedAt))`
- `has_open_gh_issues` → `.projects[].open_gh_issues_count > 0`
- `has_draft_prs` → `.projects[].user_open_prs[].isDraft == true`
- `has_sentry` → `"sentry"` in `.existing_mcps`
- `has_linear` → `"linear"` in `.existing_mcps`
- `has_slack` → `"slack"` in `.existing_mcps`
- `has_test_config` → `.projects[].verify_methods[] | .name == "test"` (any project)
- `has_lint_config` → `.projects[].verify_methods[] | .name == "lint"`
- `has_typecheck_config` → `.projects[].verify_methods[] | .name == "typecheck"`
- `has_stale_branches` → `.projects[].stale_branches_count > 5`
- `reviewer_persona_enabled` → evaluated POST-Phase-3 (Phase 1 runs before Phase 3, so for picker purposes treat as ALWAYS TRUE; if user later disables in Phase 3, the rendered subagent-reviewer.md is skipped but the recipe still ships with a note "needs reviewer persona — re-enable or skip")

**`user_mentioned:<keyword>` triggers (free-text match against Q1.1):**
- Literal keyword after the colon is matched case-insensitively as a substring against `q1_1_freeform`
- Plus small synonym table for common buckets:
  - `bug` ⊃ {"error", "crash", "broken", "regression", "bug-fix"}
  - `review` ⊃ {"PR", "feedback", "code review", "review comments"}
  - `clean` ⊃ {"tidy", "refactor", "cleanup"}
  - `deps` ⊃ {"dependency", "outdated", "upgrade"}
  - `finish` ⊃ {"complete", "done", "wrap up"}
- All other `user_mentioned:X` triggers are pure literal substring match (e.g. `user_mentioned:WIP` matches "WIP" / "wip" / "Wip" in q1_1_freeform)

**Unrecognized `has_*` triggers** evaluate to FALSE by default. To add a new trigger, register it in the catalog above first, then reference it in a recipe.

Only show recipes where at least one trigger fires, with the triggering evidence quoted (real numbers from scan).

Present via `AskUserQuestion` multi-select. Persist picks as `.recipes = ["pr_responder", "bug_triager"]`.

Always include "Custom — exactly what you described" as a fallback option, regardless of triggers.

---

