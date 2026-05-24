## PHASE 2 — Services & inputs

### Q2.1 — Service map

**Degeneracy check (auto-skip):** if for the chosen recipes:
- `services_to_install` is EMPTY (everything needed is already connected), AND
- no optional services exist that the user might want

→ SKIP Q2.1 entirely. Print info: "Using <list of services>. Moving on." (GAP #22 fix.)

Otherwise:

For each chosen recipe, derive required + helpful services from its `required_services` field. Union them with `.existing_mcps` to determine "already connected" vs "need to install".

**Chat tool discovery beyond Slack (GAP #1 fix):** if NO chat-tool MCP is connected (Slack/Discord/Telegram/Teams not in `.existing_mcps`) AND a recipe needs chat input (e.g., bug feed from a chat channel) — ask: "Do you use a team chat tool? (Slack/Discord/Telegram/Microsoft Teams/none)". Then install accordingly via mcp-registry.

For "need to install" candidates not in the recipes' required list, query mcp-registry:
```
mcp__mcp-registry__suggest_connectors with keywords from Q1.1 + recipe names
```

Build the service map and present per the yaml's q2_1 entry. Multi-select skip list.

Also include the special "Your own Claude Code session history" option (no install needed, just a permission flag). If user wants this, set `.read_cc_history = true`.

**REQUIRED post-Q2.1 derivation step** (must run BEFORE evaluating Q2.2's `depends_on: len(services_to_install) > 0`):

```bash
# After Q2.1 answers persisted to $ANSWERS_JSON:
jq --argjson existing "$(jq '.existing_mcps // []' "$SCAN_JSON")" '
  .services_to_install = (
    ((.services_chosen // []) - $existing) | unique
  )
' "$ANSWERS_JSON" > "$ANSWERS_JSON.tmp" && mv "$ANSWERS_JSON.tmp" "$ANSWERS_JSON"
```

If `services_to_install` is empty after this, Q2.2 skips cleanly. If non-empty, the loop fires.

**REQUIRED post-Q2.1 derivation step #2 — `convention_checker_enabled`:**

Scan each user project for codified-convention files; if any are present, gate the `convention-checker` subagent template to render in Phase 10.

```bash
# Detect rule files in any user project. Phase-0 should have already populated
# $SCAN_JSON.projects[].rule_files via:
#   find "$path" \( -path "*/.cursor/rules/*.mdc" -o -name ".eslintrc*" \
#                   -o -name "eslint.config.*" -o -name "biome.json" \
#                   -o -name ".prettierrc*" -o -name "prettier.config.*" \
#                   -o -name ".editorconfig" \) -maxdepth 5 -not -path "*/node_modules/*"
# If you skipped that, run it now and persist to $SCAN_JSON.projects[].rule_files.

CONV_ENABLED=$(jq '[.projects[]?.rule_files // [] | length] | add > 0' "$SCAN_JSON")
jq --argjson e "$CONV_ENABLED" '.convention_checker_enabled = $e' "$ANSWERS_JSON" > "$ANSWERS_JSON.tmp" && mv "$ANSWERS_JSON.tmp" "$ANSWERS_JSON"
```

When `convention_checker_enabled = true`, Phase 10 renders `<install>/.claude/agents/convention-checker.md`, and `prompt.md`'s ORCHESTRATION section routes through it BEFORE the reviewer. When false, the subagent is skipped (no rule sources → nothing to check against).

### Q2.2 — Install missing services (loop per missing)

For each missing service the user wants:
- Look up install command in mcp-registry (or `MCP_PATTERNS.md` for known popular ones)
- Show user what it does (description from registry)
- Get user's OK
- Execute install in one bash block (no interactive prompts)
- Verify with `claude mcp list` post-install
- For OAuth: open URL in browser, wait for callback (give clear instructions)
- Smoke test: call one read-only tool of the MCP

See `MCP_PATTERNS.md` for the universal install procedure.

### Q2.3 — Service READ narrowing (loop per connected, tier-gated)

**Universal pattern — works for any MCP, not just the popular ones.** For each connected service relevant to the agent's job:
1. List its tools via the MCP's `list_*` operations (`list_channels`, `list_teams`, `list_projects`, `list_repos`, `list_workspaces`, etc.)
2. For each list returned, render as a multi-select checklist. If the MCP returns usage stats (message counts, recent activity), surface them as preselect hints
3. Smart preselect:
   - prefer units the user is a member of / has activity in / is assigned to
   - prefer units mentioned in the user's recent Slack messages / commits
4. Persist as `.services_scoping[mcp_id] = {scoping_units: [...]}`

The wording emphasizes READ — the agent never writes here. Q2.4 handles per-tool write opt-in separately. See `MCP_PATTERNS.md` for the introspection pattern.

In Minimal tier: skip Q2.3 entirely. Default narrowing: assignee=me, my DMs only, my repos only, unresolved errors only.

### Q2.4 — Active writes (Full only, opt-in)

**Principle: night agent is a producer, not a poster.** Default: agent reads, drafts, generates patches; user reviews + applies in the morning. Active writes (sending DMs, posting comments, updating ticket statuses) are OFF by default for every MCP. This is enforced at the settings.json deny-list level — write tools are blocked unless the user explicitly opts them in here.

**What counts as a "write tool"** (auto-detected per installed MCP):
- Slack: `slack_send_message`, `slack_send_message_draft`, `slack_add_reaction`, `slack_schedule_message`, `slack_create_*`, `slack_update_canvas`
- Linear: `save_issue`, `save_comment`, `save_status_update`, `save_document`, `create_attachment`, `delete_*`
- GitHub (via gh CLI): `gh issue comment`, `gh pr comment`, `gh pr review`, `gh issue create`, `gh issue close`, `gh pr close`
- Gmail: `create_draft`, `create_label`, `delete_label`, `update_label`, `label_*`
- Drive / Notion / Discord / etc. — analogous CRUD detection

**REQUIRED pre-Q2.4 derivation step** (must run BEFORE evaluating Q2.4's `depends_on: len(write_capable_tools_detected) > 0`):

```bash
# Hard-coded catalog of write tools per known MCP. Crossed with $SCAN_JSON.existing_mcps.
# Each entry: {mcp, tool, label} so wizard can render checklist labels later.
jq --argjson catalog '[
  {"mcp":"slack","tool":"slack_send_message","label":"Slack: send message"},
  {"mcp":"slack","tool":"slack_send_message_draft","label":"Slack: send message-draft"},
  {"mcp":"slack","tool":"slack_add_reaction","label":"Slack: add emoji reaction"},
  {"mcp":"slack","tool":"slack_schedule_message","label":"Slack: schedule message"},
  {"mcp":"slack","tool":"slack_update_canvas","label":"Slack: update canvas"},
  {"mcp":"slack","tool":"slack_create_canvas","label":"Slack: create canvas"},
  {"mcp":"slack","tool":"slack_create_conversation","label":"Slack: create conversation"},
  {"mcp":"linear","tool":"save_issue","label":"Linear: create/update issue"},
  {"mcp":"linear","tool":"save_comment","label":"Linear: comment on issue"},
  {"mcp":"linear","tool":"save_status_update","label":"Linear: status update"},
  {"mcp":"linear","tool":"save_document","label":"Linear: save document"},
  {"mcp":"linear","tool":"create_attachment","label":"Linear: create attachment"},
  {"mcp":"linear","tool":"delete_comment","label":"Linear: delete comment"},
  {"mcp":"gmail","tool":"create_draft","label":"Gmail: create draft"},
  {"mcp":"gmail","tool":"create_label","label":"Gmail: create label"},
  {"mcp":"gmail","tool":"label_message","label":"Gmail: label message"},
  {"mcp":"gmail","tool":"label_thread","label":"Gmail: label thread"}
]' --argjson existing "$(jq '.existing_mcps // []' "$SCAN_JSON")" '
  .write_capable_tools_detected = [
    $catalog[] | select(.mcp as $m | $existing | index($m))
  ]
  # gh CLI write commands are always available if gh is authed — add them too:
  + (if ($existing | index("github")) then [
      {"mcp":"gh","tool":"pr_comment","label":"GitHub: comment on PR"},
      {"mcp":"gh","tool":"issue_comment","label":"GitHub: comment on issue"},
      {"mcp":"gh","tool":"pr_review","label":"GitHub: post PR review"},
      {"mcp":"gh","tool":"issue_create","label":"GitHub: create issue"},
      {"mcp":"gh","tool":"pr_close","label":"GitHub: close PR"},
      {"mcp":"gh","tool":"issue_close","label":"GitHub: close issue"}
    ] else [] end)
' "$ANSWERS_JSON" > "$ANSWERS_JSON.tmp" && mv "$ANSWERS_JSON.tmp" "$ANSWERS_JSON"
```

**Conditional:** skip Q2.4 entirely if `len(write_capable_tools_detected) == 0` (none of the connected MCPs expose write surfaces).

Multi-select. Defaults to empty (= all denied). Persist as `.write_opt_in = ["slack:slack_add_reaction", "gh:pr_comment"]` (qualified by mcp_id).

**Wizard wiring:** settings.json template denies ALL write tools by default. The render step iterates `.write_opt_in` and REMOVES the matching entries from the deny list before write. Prompt.md gets a hard "DO NOT WRITE / DO NOT SEND" preamble that lists exceptions explicitly (the opted-in tools).

---

