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

**Conditional:** skip Q2.4 entirely if `len(write_capable_tools_detected) == 0` (none of the connected MCPs expose write surfaces).

Multi-select. Defaults to empty (= all denied). Persist as `.write_opt_in = ["slack:slack_add_reaction", "gh:pr_comment"]` (qualified by mcp_id).

**Wizard wiring:** settings.json template denies ALL write tools by default. The render step iterates `.write_opt_in` and REMOVES the matching entries from the deny list before write. Prompt.md gets a hard "DO NOT WRITE / DO NOT SEND" preamble that lists exceptions explicitly (the opted-in tools).

---

