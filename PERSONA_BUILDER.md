# Reviewer Persona Builder — Concrete Algorithm

> When the wizard reaches Phase 3 and the user opts into the reviewer persona feature, this is the exact algorithm the wizard runs to produce `<install>/reviewer-style.md`. Not "the wizard figures it out" — every step here is concrete and deterministic.

This file is loaded by META_PROMPT.md at Phase 3 execution time.

---

## Inputs (gathered before this builder runs)

From `$SCAN_JSON` + Phase 3 answers:
- `reviewer_persona.handles[]` — list of GH handles user named
- `projects[].path` — user's project folder(s)
- `projects[].github` — owner/repo per project
- `projects[].stack` + `projects[].framework` — for stack-aware categorization
- `reviewer_persona.fallback_sources` per handle — if PR history empty, what else to mine

---

## Algorithm

### Step 1 — Validate reviewer is human (not a bot)

For each handle in `reviewer_persona.handles`:

```bash
gh api users/<handle> --jq '.type'
# Expected: "User"
# If "Bot" — skip with warning: "<handle> is a GitHub bot; persona builder skips bots."
```

If user insists on a bot handle (e.g., a custom internal bot), document explicitly in the persona file but treat bot voice differently.

### Step 2 — Gather PR review comments

For each (user_handle, reviewer_handle, project) triple:

```bash
# Find PRs by user where reviewer has reviewed
gh pr list \
  --repo <owner>/<name> \
  --author "$USER_HANDLE" \
  --state all \
  --limit 100 \
  --json number,reviews,comments,reviewDecisions
```

Filter to PRs where reviewer's login appears in `reviews[].author.login` OR `comments[].author.login`.

For each matching PR:

```bash
gh api "repos/<owner>/<name>/pulls/<number>/reviews" \
  --paginate \
  --jq '[.[] | select(.user.login == "<REVIEWER>")]'

gh api "repos/<owner>/<name>/pulls/<number>/comments" \
  --paginate \
  --jq '[.[] | select(.user.login == "<REVIEWER>")]'
```

Persist raw output to `/tmp/persona-builder/<reviewer>/pr-<N>.json`.

**Counts to capture:**
- Total reviews
- Total inline comments (file:line specific)
- Most recent 5 review timestamps
- Pivot data: comments per file extension, comments per file-path pattern

If total reviews + total comments **< 5**, mark the reviewer's PR-history evidence as "weak" — wizard later may ask user to point at additional sources (fallback per Q3.3).

### Step 3 — Extract verbatim quotes + context

For each comment, build a row:

```json
{
  "pr_number": 245,
  "file": "src/components/Button.tsx",
  "line": 42,
  "body": "<verbatim comment body>",
  "in_reply_to": null,
  "created_at": "2026-03-15T14:00:00Z",
  "diff_hunk": "<verbatim hunk if present>"
}
```

Persist as `/tmp/persona-builder/<reviewer>/comments.jsonl`.

Cap at most recent 50 comments per reviewer (older comments may not reflect current style).

### Step 4 — Cluster comments by category (LLM call — separate subagent)

Spawn an `Agent` subagent (type `general-purpose`) with this prompt:

> You're a code-review style analyst. Below is a list of {{ N }} review comments from `<reviewer>` on PRs by `<user>` over `<date_range>`. The project is `<stack>` + `<framework>`. 
>
> Group the comments into 10-20 categories. Each category should be:
> - A short noun phrase (3-7 words) describing what the reviewer cares about
> - Sized by frequency (most-frequent categories first)
> - Stack-aware: for `<stack>`, expected categories often include `<stack-specific examples>`
>
> **Don't rely on keyword matching alone**. Look at the SHAPE of comments too:
> - GitHub `​```suggestion``` ` blocks (inline code rewrites) often dominate the top category — bucket them by what kind of change the suggestion makes (rename, extract const, single-object args, etc.) not as a single "suggestion" bucket.
> - Repeated stock phrasings ("Please ...", "Why ...?", "Can we ...?", "I wonder if ...") indicate voice patterns, not category boundaries — record them under `voice_markers.opener_patterns`, not as categories.
> - Code-quote-only comments (no prose) — categorize by what the quoted code does, not the comment text.
>
> Return JSON:
> ```json
> {
>   "categories": [
>     {
>       "name": "...",
>       "frequency": N,
>       "examples": ["<verbatim quote>", "<verbatim quote>"],
>       "severity": "P0|P1|P2",
>       "rationale": "what the reviewer cares about with this"
>     }
>   ],
>   "anti_patterns_not_flagged": ["..."],
>   "voice_markers": {
>     "tone": "terse|surgical|expansive|collegial|adversarial",
>     "softeners": ["pls", "🙏", "?", "+1"],
>     "opener_patterns": ["Please ...", "Why ...?", "Can we ...?", "I wonder if ..."]
>   }
> }
> ```

**Stack-aware category hints to pass into the prompt:**

| Stack | Common reviewer concerns |
|---|---|
| `python` | type hints, mypy strict, Pythonic idioms, exception handling, fixtures, mocking strategy |
| `react-native` | hooks deps, Reanimated correctness, navigation patterns, RN list virtualization, native module wrappers |
| `nextjs` | server/client component boundary, App Router vs Pages, hydration, NextAuth misuse |
| `go` | error wrapping, goroutine leaks, context propagation, interface design |
| `rust` | lifetime correctness, Result/Option chaining, async patterns, unsafe blocks |
| `ruby` | block-vs-proc, ActiveRecord N+1, Sidekiq idempotency |
| `java` | NPE risk, generics variance, JPA lazy loading |

If stack isn't in this table — pass a generic hint: "type safety, naming, function length, test coverage, error handling".

### Step 5 — Render persona file

Use this template for `<install>/reviewer-style.md`:

```markdown
# Reviewer Profile: {{ reviewer_display_name }}

> Loaded by the night-shift agent before reviewing any patch. Goal: anticipate
> the exact comments {{ reviewer_pronoun }} would leave so patches are
> pre-emptively cleaner.
>
> Compiled from {{ N }} review comments on user's PRs (range #{{ earliest_pr }} → #{{ latest_pr }}, {{ date_range }}).
> Stack: {{ stack }} ({{ framework }}).

---

## Identity

- GitHub handle: `{{ handle }}`
- Display name: {{ display_name }}  ({{# if anonymize }}anonymized as Senior Reviewer {{ idx }}{{/if}})
- Role inferred: {{ role_inferred_from_review_volume }}
- Language in reviews: {{ detected_language }}

## Voice

- Tone: {{ voice_markers.tone }}
- Length preference: {{ length_preference }}  (most comments are {{ avg_comment_length }} chars)
- Common softeners: {{ voice_markers.softeners }}
- Frequent opener patterns:
{{# each voice_markers.opener_patterns }}
  - `{{ this }}` — examples: {{ examples_of_opener }}
{{/ each }}

## Top critique categories (ranked by frequency)

{{# each categories }}

### {{ @index_plus_1 }}. {{ name }} ({{ severity }}, frequency: {{ frequency }})

{{ rationale }}

**Verbatim examples:**
{{# each examples }}
- "{{ this }}"
{{/ each }}

**Self-check before submitting a patch:** {{ self_check_advice }}

---
{{/ each }}

## Anti-patterns NOT flagged (saves false-positive burn)

{{# each anti_patterns_not_flagged }}
- {{ this }}
{{/ each }}

## P0 always-flag list

(Categories above marked P0 — patches must pass these.)

{{# each categories_p0 }}
- {{ this.name }}
{{/ each }}

## Recent style evolution

{{ recent_evolution_summary }}
```

### Step 6 — Sanity-check the output

Before declaring the persona file done:

1. File size between 5KB and 50KB (too small → not enough signal; too big → useless)
2. At least 5 categories with frequency ≥ 2
3. At least 1 P0 category
4. Voice markers extracted successfully

If any check fails, regenerate with a warning to the user: "Persona file quality is uneven — fewer reviews to draw from than ideal. Output saved at <path> but may underperform."

---

## Fallback sources (from Q3.3)

If reviewer has < 5 PR review comments on user's PRs:

### Source: their public GH activity
```bash
gh api "search/issues?q=author:<reviewer>+is:pr+is:merged&per_page=50" \
  --jq '.items[].html_url'
# Then fetch each PR's review comments BY the reviewer
```

Lower-confidence persona — they reviewed others' code, not user's. Note this in the persona file's "evidence" section.

### Source: Slack DMs
If Slack MCP connected AND user picked DMs as fallback:
```
mcp__slack__read_dm  with channel = DM_id_between_user_and_reviewer
```
Extract messages by reviewer in the last 90 days. Treat as conversational style (not formal review style — note distinction in persona file).

### Source: pasted document
User provides text content. Wizard parses for category signals using the same Step 4 LLM call, but with "(content is informal style guide, not actual review comments — categorize accordingly)" context.

---

## Output destination

`<install>/reviewer-style.md` — committed to install dir's git if `gh_repo.create` is on (anonymized version if user picked anonymize).

If multiple reviewers (e.g., the maintainer has Basia + Don):
- Generate `<install>/reviewer-styles/<handle>.md` per reviewer
- Plus a roll-up `<install>/reviewer-style.md` indexing them with cross-references

The agent's prompt at run time loads the relevant persona file before running the `reviewer` subagent.

---

## Failure modes

- **No PR overlap found** → Wizard says: "Couldn't find any PR reviews by `<handle>` on your code. Going to ask you for a fallback source (Q3.3 loop)."
- **All comments are LGTM-only or +1** → Persona file says "minimal critique evidence — reviewer is hands-off or focused on approvals not changes". Still useful for setting tone.
- **Subagent LLM call returns malformed JSON** → Retry once with stricter format prompt. If still malformed, fall back to a manual category list per stack.

---

## Privacy & ethics

The generated `reviewer-style.md` contains the reviewer's real name + GH handle + verbatim quotes. If `reviewer_persona.anonymize` is true:
- Replace all `<handle>` mentions with `Senior Reviewer <N>`
- Strip display names + emails
- Keep verbatim quotes (they're voice signal, not identifying)

If the user picks "Yes, public repo" in Q0.4 AND anonymization is OFF: warn the user explicitly before pushing — their reviewer's name + style will be in the public repo.
