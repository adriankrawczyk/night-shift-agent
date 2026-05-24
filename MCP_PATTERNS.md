# MCP Install Patterns — Universal Procedure

> The wizard handles every MCP install through one universal procedure. The recipes below are the primary source of install commands. The `mcp-registry` MCP (when available in the user's Claude Code session) is used to enrich/cross-check those recipes and to look up MCPs not in this file — it's an enhancer, not a hard dependency.
>
> Why: `mcp-registry` is not consistently available across Claude Code installs (it ships with certain plugin bundles, not the base CLI), and there is no `@anthropic/mcp-registry` npm package to bootstrap from. The wizard must work without it.

---

## Real `claude mcp add` syntax (Claude Code CLI)

Verified against `claude mcp add --help`:

```
Usage: claude mcp add [options] <name> <commandOrUrl> [args...]

Options:
  -t, --transport <transport>   stdio | sse | http   (default: stdio)
  -e, --env <env...>            -e KEY=value (repeatable)
  -H, --header <header...>      -H "X-Api-Key: abc"  (repeatable, HTTP/SSE)
  -s, --scope <scope>           local | user | project   (default: local)
  --client-id <clientId>        OAuth client ID for HTTP/SSE
  --client-secret               Prompt for OAuth client secret
  --callback-port <port>        Fixed OAuth callback port
```

**Three install shapes you will encounter:**

1. **HTTP (modern, most managed services)**:
   ```bash
   claude mcp add -s user --transport http <name> <url>
   # Example: claude mcp add -s user --transport http sentry https://mcp.sentry.dev/mcp
   ```

2. **stdio with env vars (older / self-hosted)** — `<name>` MUST come before any `-e` flags:
   ```bash
   claude mcp add -s user <name> -e KEY1=val1 -e KEY2=val2 -- <command> [args...]
   # Example: claude mcp add -s user github -e GITHUB_PERSONAL_ACCESS_TOKEN=ghp_xxx -- npx -y @modelcontextprotocol/server-github
   ```
   **Why the order matters:** `-e` is declared as variadic in the CLI (commander.js `<env...>`),
   so if you put `-e KEY=v` *before* `<name>`, commander greedily consumes `<name>` as another env value
   and the install fails with `Invalid environment variable format: <name>`. Verified against
   `claude mcp` v2.1.144 — the official help text's `-e API_KEY=xxx my-server --` example is
   actually wrong on real CLIs. Put the name first.

3. **stdio with no env (local binary)**:
   ```bash
   claude mcp add -s user <name> -- <command> [args...]
   # Example: claude mcp add -s user argent -- argent mcp
   ```

The `--` separator is mandatory before the command for stdio servers — it tells the CLI that what follows is the command + its args, not more `claude mcp add` options.

---

## Universal install procedure

For any MCP the user wants to install:

```
1. Look up install metadata. In order of preference:
     a. Recipe in "Known popular MCPs" below — fast, deterministic.
     b. mcp__mcp-registry__search_mcp_registry (only if that tool exists in this session) —
        useful for MCPs not in the recipes, or to cross-check that a recipe is current.
     c. WebSearch for "<name> mcp claude install" as last resort.
   → produces: { name, description, transport, command_or_url, env_vars[], oauth_url? }

2. Show user a 2-line confirmation:
   - Name + description (from registry or the recipe below)
   - What setup it needs (OAuth login in browser / paste an env var / no setup)
   Wait for explicit Y/N/manual.

3. If env vars needed, prompt the user once per var:
     For each var in env_vars[]:
       read -s -p "Enter value for $var: " VAL
       export ${var}_VAL="$VAL"   # held in shell only, not written to disk

4. Execute install (always use `-s user` so MCP is available regardless of cwd):
   - HTTP:    claude mcp add -s user --transport http <name> <url>
   - stdio:   claude mcp add -s user <name> [ -e KEY=val ... ] -- <cmd> [args...]
   - For OAuth-protected HTTP MCPs, the CLI opens the browser and handles callback.

   Note on scope: `local` (the default) ties the MCP to the cwd where you ran `claude mcp add`,
   which is fragile for an autonomous night-shift agent that may run from `$INSTALL_DIR` or from
   `~/.config/night-shift-agent/wizard-state/`. `user` scope persists across all your projects.

5. Verify install:
     claude mcp list 2>/dev/null | grep -F "<name>"
   - Must show "✓ Connected" (anything else = not ready).

6. Smoke test:
   - Pick one read-only tool from the MCP (e.g., `list_*`, `get_*`, `find_*`)
   - Invoke it. Expect success — or at minimum a meaningful auth error (not a connection error).

7. Persist to scan:
     jq --arg name "<name>" '.existing_mcps += [$name]' "$SCAN_JSON" > tmp && mv tmp "$SCAN_JSON"
```

If any step fails:
- Print the error verbatim (don't paraphrase — user might need to debug)
- Offer the manual install URL from the registry
- Mark service as `install_failed` or `auth_pending` in `$ANSWERS_JSON`
- Continue the wizard — never let one MCP block everything

---

## Known popular MCPs (recipes baked in)

These are the most common MCPs likely to be requested. The registry might return slightly different commands depending on version — **always prefer the registry's current answer over these recipes**. The recipes are a fallback when the registry is unreachable or has stale data.

Note: many modern managed services have HTTP endpoints with built-in OAuth — no env var, no token paste, the browser handles it. Those are the simplest installs.

### GitHub (`mcp__github__*`)
**Auth:** Personal access token (or `gh` CLI keychain if MCP supports it).
**Install:**
```bash
claude mcp add -s user github -e GITHUB_PERSONAL_ACCESS_TOKEN=ghp_xxx -- npx -y @modelcontextprotocol/server-github
```
**Smoke test:** `mcp__github__get_repository` on any public repo.

### Slack (`mcp__slack__*`)
**Auth:** OAuth via Claude desktop ("claude.ai Slack" managed connector) — easiest path.
**Install (managed, recommended):** Open Claude desktop → Settings → Connectors → enable Slack.
**Install (self-hosted, advanced):**
```bash
claude mcp add -s user slack -e SLACK_BOT_TOKEN=xoxb-xxx -e SLACK_TEAM_ID=Txxx -- npx -y @modelcontextprotocol/server-slack
```
**Smoke test:** `mcp__slack__slack_search_public` with a basic query.
**Scoping units:** channels, DMs, users.

### Linear (`mcp__linear__*`)
**Auth:** Built-in OAuth (HTTP transport — no token paste).
**Install:**
```bash
claude mcp add -s user --transport http linear https://mcp.linear.app/mcp
```
First tool call triggers OAuth in browser.
**Smoke test:** `mcp__linear__list_teams`.
**Scoping units:** teams, projects, cycles.

### Sentry (`mcp__sentry__*`)
**Auth:** Built-in OAuth (HTTP).
**Install:**
```bash
claude mcp add -s user --transport http sentry https://mcp.sentry.dev/mcp
```
**Smoke test:** `mcp__sentry__find_organizations`.
**Scoping units:** organizations, projects, environments.

### Gmail (`mcp__gmail__*`)
**Auth:** Google OAuth — easiest via Claude desktop's managed "claude.ai Gmail" connector.
**Install (managed, recommended):** Claude desktop → Settings → Connectors → Gmail.
**Install (self-hosted, advanced) — no official package, pick a community one:**
```bash
# Option 1: gmail-mcp (domdomegg) — most maintained
claude mcp add -s user gmail -- npx -y gmail-mcp

# Option 2: @gongrzhe/server-gmail-autoauth-mcp — auto OAuth flow
claude mcp add -s user gmail -- npx -y @gongrzhe/server-gmail-autoauth-mcp
```
(Will spin up its own OAuth callback on first run.)
**Smoke test:** list labels or threads.
**Note:** verify the latest community package at install time — Google has no official MCP yet.

### Google Drive (`mcp__drive__*` or `mcp__gdrive__*`)
**Auth:** Google OAuth — managed connector recommended.
**Install (managed, recommended):** Claude desktop → Settings → Connectors → Google Drive.
**Install (self-hosted, advanced):**
```bash
claude mcp add -s user gdrive -- npx -y @modelcontextprotocol/server-gdrive
```
**Smoke test:** Drive search for a known file.

### Google Calendar (`mcp__calendar__*`)
**Install (managed only at present):** Claude desktop → Settings → Connectors → Calendar.

### Notion (`mcp__notion__*`)
**Auth:** Integration token (Notion → Settings → Integrations → New).
**Install:**
```bash
claude mcp add -s user notion -e NOTION_API_KEY=secret_xxx -- npx -y @notionhq/notion-mcp-server
```
**Smoke test:** list databases / search pages.

### Discord (`mcp__discord__*`)
**Auth:** Bot token (Discord Developer Portal → Application → Bot).
**Install:** No official Discord MCP from Discord. Community options (pick one — `discord-mcp` is most widely-used as of 2026-05):
```bash
# Option 1: community discord-mcp (markov_kernel)
claude mcp add -s user discord -e DISCORD_BOT_TOKEN=xxx -- npx -y discord-mcp

# Option 2: more tools per server (@pasympa/discord-mcp, 90+ tools)
claude mcp add -s user discord -e DISCORD_BOT_TOKEN=xxx -- npx -y @pasympa/discord-mcp

# Option 3: @missionsquad/mcp-discord (older, lighter)
claude mcp add -s user discord -e DISCORD_BOT_TOKEN=xxx -- npx -y @missionsquad/mcp-discord
```
**Smoke test:** list guilds (servers).
**Note:** verify the latest community package + scope at install time — Discord MCP ecosystem still settling. Run `npm search "discord mcp"` to see current options.

### Jira (`mcp__jira__*`)
**Auth:** API token + email + host.
**Install — no official Atlassian package, pick a community one:**
```bash
# Option 1: jira-mcp (camdenclark2022) — simple, smithery-listed
claude mcp add -s user jira \
  -e JIRA_HOST=https://acme.atlassian.net \
  -e JIRA_EMAIL=you@acme.com \
  -e JIRA_API_TOKEN=xxx \
  -- npx -y jira-mcp

# Option 2: @rokealvo/jira-mcp — more features, recently updated
claude mcp add -s user jira \
  -e JIRA_HOST=https://acme.atlassian.net \
  -e JIRA_EMAIL=you@acme.com \
  -e JIRA_API_TOKEN=xxx \
  -- npx -y @rokealvo/jira-mcp
```
**Note:** Atlassian has no official MCP yet. Verify the package at install time.
**Smoke test:** list projects.

### Figma (`mcp__figma__*`)
**Auth:** Built-in OAuth (HTTP).
**Install:**
```bash
claude mcp add -s user --transport http figma https://mcp.figma.com/mcp
```
**Smoke test:** `mcp__figma__whoami`.

### Exa search (`mcp__exa__*`)
**Auth:** Built-in (HTTP).
**Install:**
```bash
claude mcp add -s user --transport http exa https://mcp.exa.ai/mcp
```
**Smoke test:** `mcp__exa__web_search_exa`.

### Argent (mobile sim/emulator — `mcp__argent__*`)
**Auth:** none.
**Install:**
```bash
brew install software-mansion/argent/argent
claude mcp add -s user argent -- argent mcp
```
**Smoke test:** `mcp__argent__list-devices`.

### context7 docs (`mcp__context7__*`)
**Auth:** none.
**Install (as a plugin, recommended):** via Claude Code's plugin system.
**Install (manual stdio):**
```bash
claude mcp add -s user context7 -- npx -y @upstash/context7-mcp
```
**Smoke test:** `mcp__context7__resolve-library-id` with a known library name.

### mcp-registry (optional, not user-installable)
There is no public `@anthropic/mcp-registry` npm package — `mcp-registry` tools (`mcp__mcp-registry__*`) ship with certain Claude Code plugin bundles and aren't installable via `claude mcp add`. If `claude mcp list` doesn't include it and the wizard's session doesn't surface `mcp__mcp-registry__*` deferred tools, treat the registry as unavailable and rely on the recipes above + WebSearch fallback.

---

## Distinguishing "claude.ai Foo" managed connectors from `claude mcp add` installs

`claude mcp list` shows two flavors:
- Names prefixed `claude.ai ` (e.g., `claude.ai Google Drive`, `claude.ai Slack`) are managed by the Claude desktop app's Connectors settings. **You cannot install or remove these with `claude mcp add` / `claude mcp remove`.** Direct the user to the desktop app.
- Names without that prefix (e.g., `sentry`, `linear`, `argent`) are CLI-installed and fully manageable from `claude mcp add` / `claude mcp remove`.

When the user asks for "Slack" or "Gmail" or "Drive" or "Calendar", prefer the managed connector if they have Claude desktop installed — it handles OAuth refresh, scopes, and tenant selection without manual token rotation. Fall back to the self-hosted stdio install only if managed isn't an option.

---

## Scoping introspection (Q2.3 generic narrowing)

For ANY connected MCP, the wizard can figure out what to ask the user by introspecting the MCP's tools:

```
1. Get the MCP's tool list:
   claude mcp tools <name>
   → list of available tools with their input schemas

2. Identify scoping tools — tools whose name starts with `list_` (or `find_`, `search_`)
   and that return entities the user might want to filter by:
     list_channels    / slack_search_channels  → ask "which channels?"
     list_repos                                → ask "which repos?"
     list_teams                                → ask "which teams?"
     list_projects    / find_projects          → ask "which projects?"
     list_users                                → ask "which users (for DMs)?"

3. For each scoping tool, call it (read-only) and get the list of actual values.

4. Present multi-select to user with autocomplete from the actual list.

5. Save user picks to scan/answers as scoping config:
     services_scoping[<mcp>][<unit>] = ["channel_1", "channel_2"]
```

The generated `prompt.md` uses this scoping config to know which channels/repos/teams to read from at run time.

---

## OAuth flow handling

For MCPs that use OAuth:

1. **HTTP MCPs with built-in OAuth** (Linear, Sentry, Figma, Exa, claude.ai-managed): the Claude CLI handles the browser callback automatically the first time you invoke a tool. Nothing for the wizard to do beyond printing "you'll be sent to the browser to authorize on first use."

2. **stdio MCPs with their own OAuth server** (older Gmail/Drive npm packages): they spin up a local HTTP listener on a random port during install and print the URL. The wizard should:
   ```
   Print: "Open this URL in your browser:  https://..."
          "After you click Allow, you'll be redirected back automatically."
   Wait with a 5-min timeout.
   If callback doesn't fire, ask: "Did the auth complete? [Y/N/retry]"
   ```

3. Never try to intercept the callback yourself — let the MCP do it.

---

## Read-CC-history "service" (no MCP install)

Reading `~/.claude/projects/*` is just file reads, not an MCP. If user opts in at Q2.1:

- Save `.read_cc_history = true` in answers
- Generated `prompt.md` includes a "before STEP 1, grep your CC history for context" instruction
- Wizard adds a `Read(~/.claude/projects/**)` permission to `settings.json:permissions.allow`
- No install step needed

---

## Failure modes

### MCP install fails (CLI exit code non-zero)
1. Print the install error verbatim
2. If `mcp__mcp-registry__search_mcp_registry` is available, cross-check the install command in case the recipe is stale.
3. Usually means npm/network/permissions issue. Show user the manual command.
4. Mark service as `install_failed` in answers, continue.

### OAuth callback times out
1. Ask user "Did the auth complete in your browser?"
2. If yes — retry smoke test
3. If no — mark service as `auth_pending`, continue (user can finish auth manually later via `claude mcp list` to retry)

### Smoke test fails after install
1. Print the exact tool call + error
2. Try a different read-only tool (some MCPs have one tool that's flaky)
3. If still failing — mark `installed_but_broken`, continue

### `claude mcp list` shows `! Needs authentication`
Treat as `auth_pending`. The MCP is installed but the user hasn't completed OAuth. First tool call will re-trigger the browser flow.

### `claude mcp list` shows `✗ Error`
Treat as `installed_but_broken`. Capture the error from `claude mcp list` and surface it to the user with the suggested fix (often `claude mcp remove <name>` and re-add).

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

The deny list (sudo, rm -rf ~, etc.) is hardcoded in the template — no MCP install can ever override it.
