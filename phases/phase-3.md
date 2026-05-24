## PHASE 3 — Reviewer persona

Skipped entirely in Minimal tier.

### Q3.1 — Opt-in
Standard. Persist `.reviewer_persona.enabled = bool`.

### Q3.2 — Who (if enabled)
Free text list of GH handles. For each:
- `gh api users/<handle>` — validate exists AND not a bot (`.type == "User"`)
- **On `404` / not-a-User**: don't silently skip. Show inline error ("`@<handle>` doesn't look like a real GitHub User — typo? bot? deleted account?") and re-prompt for this slot. Same protocol as Q0.1 username validation. After 3 failed attempts on the same slot, offer to skip it.
- If bot: skip with warning "GH bot — persona builder doesn't model bot reviewers" (GAP #11 fix)
- Scan user's PRs for this reviewer:
  ```bash
  gh pr list --author @me --state all --limit 100 --json number,reviews \
    | jq --arg r "$HANDLE" '[.[] | select(.reviews[].author.login == $r) | .number] | length'
  ```
- Report back with real numbers ("14 reviews in 6 months").

Persist `.reviewer_persona.reviewers = [{handle, review_count, found}]`.

**REQUIRED post-Q3.2 derivation step** (must run BEFORE evaluating Q3.3's `depends_on: ... AND len(reviewers_with_no_pr_history) > 0`):

```bash
jq '
  .reviewers_with_no_pr_history = [
    .reviewer_persona.reviewers[]? | select(.review_count == 0) | .handle
  ]
' "$ANSWERS_JSON" > "$ANSWERS_JSON.tmp" && mv "$ANSWERS_JSON.tmp" "$ANSWERS_JSON"
```

Empty array → Q3.3 skips cleanly (all reviewers had reviews). Non-empty → Q3.3 fires once per missing-history handle.

### Q3.3 — Source if no PR history (loop per "0 reviews" person)
Standard. If they pick "Slack DMs" and Slack isn't connected, gracefully degrade to other options.

### Q3.4 — Anonymization (Full tier only)
Standard. Persist `.reviewer_persona.anonymize = bool`.

### Persona file generation

Use `PERSONA_BUILDER.md` for the concrete algorithm. Do NOT improvise. The builder:
1. Validates each handle is a User not a Bot
2. Gathers raw PR review comments via `gh api`
3. Clusters by category via a separate `Agent` subagent call (stack-aware hints)
4. Renders to `<install>/reviewer-style.md` (or `<install>/reviewer-styles/<handle>.md` for multi-reviewer)
5. Sanity-checks output size + category count

If any reviewer has < 5 reviews on user's PRs → loop into Q3.3 to gather fallback sources, then build persona from those.

---

