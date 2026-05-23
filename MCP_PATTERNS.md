# MCP Install Patterns — Universal Procedure

> The wizard never hardcodes a list of "supported MCPs". Every MCP install goes through this universal procedure, driven by `mcp-registry` queries. This file documents the algorithm + edge cases.

---

## Universal install procedure

For any MCP the user wants to install:

```
1. Query mcp-registry for install metadata:
     mcp__mcp-registry__search_mcp_registry with the MCP's name/keyword
   → returns: { name, description, install_command, env_vars, oauth_url?, registry_url }

2. Show user a 2-line confirmation:
   - Name + description (from registry)
   - What setup it needs (OAuth login / env var paste / no setup)
   Wait for explicit Y/N/manual.

3. If Y, execute install:
   - Run install_command via Bash tool
   - For OAuth MCPs: open oauth_url in browser, instruct user, wait for callback
   - For env-var MCPs: prompt user for value, store via `claude mcp add --env KEY=VAL`

4. Verify install:
     claude mcp list | grep -F "<mcp-name>"
   - Must return success exit code

5. Smoke test:
   - Find one read-only tool from the MCP (e.g., `list_*`, `get_*`)
   - Call it via Claude Code's standard MCP tool-use
   - Expect success (or at minimum, a meaningful error — not connection refused)

6. Persist to scan:
     jq --arg name "<mcp-name>" '.existing_mcps += [$name]' "$SCAN_JSON" > tmp && mv tmp "$SCAN_JSON"
```

If any step fails:
- Show the error verbatim (don't paraphrase — user might need to debug)
- Offer manual install URL from registry
- Mark service as "skipped" in `$ANSWERS_JSON`
- Continue wizard

---

## Known popular MCPs (install recipes baked in)

These are the most common MCPs likely to be requested. The registry might return slightly different commands depending on version — always prefer the registry's current answer over these.

### GitHub (`mcp__github__*`)
**Auth:** `gh` CLI keychain (no separate token needed).
**Install:** Usually pre-installed with Claude Code. If not:
```bash
claude mcp add github --command 'npx @modelcontextprotocol/server-github'
```
**Smoke test:** `mcp__github__get_repo` on any public repo.

### Slack (`mcp__slack__*`)
**Auth:** OAuth — user authorizes the workspace via slack.com.
**Install:**
```bash
claude mcp add slack --command 'npx @modelcontextprotocol/server-slack' --env SLACK_BOT_TOKEN
```
User needs to follow OAuth URL printed during install.
**Smoke test:** `mcp__slack__list_channels`.
**Scoping units:** channels, DMs, users.

### Linear (`mcp__linear__*`)
**Auth:** API key.
**Install:**
```bash
claude mcp add linear --command 'npx @linear/mcp-server' --env LINEAR_API_KEY
```
User must paste API key from Linear settings → Account → API.
**Smoke test:** `mcp__linear__list_teams`.
**Scoping units:** teams, projects, cycles.

### Sentry (`mcp__sentry__*`)
**Auth:** Auth token from Sentry → Settings → Account → API.
**Install:**
```bash
claude mcp add sentry --command 'npx @getsentry/mcp-server' --env SENTRY_AUTH_TOKEN --env SENTRY_ORG
```
**Smoke test:** `mcp__sentry__find_organizations`.
**Scoping units:** organizations, projects, environments.

### Gmail (`mcp__gmail__*`)
**Auth:** Google OAuth.
**Install:**
```bash
claude mcp add gmail --command 'npx @modelcontextprotocol/server-gmail'
```
User completes Google OAuth in browser.
**Smoke test:** `mcp__gmail__list_labels`.

### Google Drive (`mcp__drive__*`)
**Auth:** Google OAuth (often same flow as Gmail).
**Install:**
```bash
claude mcp add drive --command 'npx @modelcontextprotocol/server-gdrive'
```
**Smoke test:** `mcp__drive__search`.

### Notion (`mcp__notion__*`)
**Auth:** Integration token.
**Install:**
```bash
claude mcp add notion --command 'npx @notionhq/notion-mcp-server' --env NOTION_API_KEY
```
**Smoke test:** `mcp__notion__list_databases`.

### Discord (`mcp__discord__*`)
**Auth:** Bot token.
**Install:**
```bash
claude mcp add discord --command 'npx @discord/mcp-server' --env DISCORD_BOT_TOKEN
```
**Smoke test:** `mcp__discord__list_servers`.

### Jira (`mcp__jira__*`)
**Auth:** API token + email.
**Install:**
```bash
claude mcp add jira --command 'npx @atlassian/jira-mcp-server' --env JIRA_HOST --env JIRA_EMAIL --env JIRA_API_TOKEN
```
**Smoke test:** `mcp__jira__list_projects`.

### Figma (`mcp__figma__*`)
**Auth:** Personal access token.
**Install:**
```bash
claude mcp add figma --command 'npx @figma/mcp-server' --env FIGMA_TOKEN
```
**Smoke test:** `mcp__figma__get_file_metadata`.

### Argent (mobile sim/emulator — `mcp__argent__*`)
**Auth:** none.
**Install:**
```bash
brew install software-mansion/argent/argent
claude mcp add argent --command 'argent mcp'
```
**Smoke test:** `mcp__argent__list-devices`.

---

## Scoping introspection (Q2.3 generic narrowing)

For ANY connected MCP, the wizard can figure out what to ask the user by introspecting the MCP's tools:

```
1. Get the MCP's tool list:
   claude mcp tools <mcp-name>
   → list of available tools with their input schemas

2. Identify scoping tools — tools whose name starts with `list_` and that
   return entities the user might want to filter by:
     list_channels  → ask "which channels?"
     list_repos     → ask "which repos?"
     list_teams     → ask "which teams?"
     list_projects  → ask "which projects?"
     list_users     → ask "which users (for DMs)?"

3. For each scoping tool, call it (read-only) and get the list of actual values.

4. Present multi-select to user with autocomplete from the actual list.

5. Save user picks to scan/answers as scoping config:
     services_scoping[<mcp>][<unit>] = ["channel_1", "channel_2"]
```

Generated `prompt.md` uses this scoping config to know which channels/repos/teams to read from at run time.

---

## OAuth flow handling

Some MCPs need OAuth in a browser. The wizard:

1. Print the OAuth URL to the user clearly:
   ```
   Open this URL in your browser to authorize:
       https://...

   After you click 'Allow', you'll be redirected to a localhost URL.
   I'll detect the redirect and continue automatically.
   ```

2. The MCP's install script typically spins up a local HTTP listener on a random port. Don't try to handle the callback yourself — let the MCP do it.

3. Wait with a 5-min timeout. If callback doesn't fire, ask user "Did the auth complete? [Y/N/retry]".

---

## Read-CC-history "service" (no MCP install)

Reading `~/.claude/projects/*` is just file reads, not an MCP. If user opts in at Q2.1:

- Save `.read_cc_history = true` in answers
- Generated `prompt.md` will include a "before STEP 1, grep your CC history for context" instruction
- Wizard adds a `Read(~/.claude/projects/**)` permission to `settings.json:permissions.allow`
- No install step needed

---

## Failure modes

### MCP install fails (npm exit code non-zero)
1. Print the install error verbatim
2. Check if MCP is actually in registry: `mcp__mcp-registry__search_mcp_registry`
3. If yes — likely OAuth issue or env var. Show user the manual command + URL.
4. Mark service as `install_failed` in answers, continue.

### OAuth callback times out
1. Ask user "Did the auth complete in your browser?"
2. If yes — retry smoke test
3. If no — mark service as `auth_pending`, continue (user can finish auth manually later)

### Smoke test fails after install
1. Print exact tool call + error
2. Try a different read-only tool (some MCPs have one tool that's flaky)
3. If still failing — mark `installed_but_broken`, continue

### mcp-registry MCP itself not installed
Bootstrap step: install it first.
```bash
claude mcp add mcp-registry --command 'npx @anthropic/mcp-registry'
```

---

## Post-install: trust gate for scopes

After every MCP install, the wizard adds the MCP's permission to `settings.json:permissions.allow`:
```json
{
  "permissions": {
    "allow": [
      "mcp__slack",
      "mcp__linear",
      "..."
    ]
  }
}
```

This is what makes the night-shift agent able to call the MCP at run time without permission prompts.

The deny list (sudo, rm -rf ~, etc.) is hardcoded in the template — no MCP can ever override it.
