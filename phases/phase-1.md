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
- "has_open_prs_with_reviews" → check `.projects[].user_open_prs[].reviews | length > 0`
- "has_draft_prs" → check `.projects[].user_open_prs[].isDraft == true`
- "has_sentry" → check `"sentry"` in `.existing_mcps`
- "has_linear" → check `"linear"` in `.existing_mcps`
- "has_test_config" → check `.projects[].verify_methods | length > 0`
- "has_stale_branches" → check `.projects[].stale_branches_count > 5`
- "user_mentioned:bug" → check Q1.1 free text contains "bug", "error", "crash" (case-insensitive)
- "user_mentioned:review" → check Q1.1 contains "review", "PR", "feedback"
- etc.

Only show recipes where at least one trigger fires, with the triggering evidence quoted (real numbers from scan).

Present via `AskUserQuestion` multi-select. Persist picks as `.recipes = ["pr_responder", "bug_triager"]`.

Always include "Custom — exactly what you described" as a fallback option, regardless of triggers.

---

