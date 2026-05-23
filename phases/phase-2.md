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

### Q2.3 — Service narrowing (loop per connected, tier-gated)

For each connected service relevant to the agent's job:
1. List its tools via the MCP's `list_*` operations
2. For each tool with scoping args (channel_id, repo, team_id, project_id, environment, etc.), ask user

This is generic. See `MCP_PATTERNS.md` for the introspection pattern.

In Minimal tier: skip Q2.3 entirely. Default narrowing: assignee=me, my DMs only, my repos only, unresolved errors only.

---

