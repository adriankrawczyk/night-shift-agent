## PHASE 0 — Preflight + project scan

Goal: get the project folder(s), do a deep scan, confirm with user, get install folder + GH repo decision.

### Project type detection refinements

When scanning each project:
- **`project_touches_ui`**: TRUE if (deps include React/Vue/Angular/RN/Svelte/Solid/Preact) OR (config files exist: playwright.config.*, cypress.config.*, detox.config.*, maestro). FALSE for backend-only projects even if auth-flow files are present. (GAP #3 fix.)
- **`python_package_manager`**: detect via lockfile in this priority — `uv.lock` → uv; `poetry.lock` → poetry; `Pipfile.lock` → pipenv; `setup.py` only → pip; `pyproject.toml` without lockfile → pip with PEP 517. (GAP #4 fix.)
- **`node_package_manager`**: similar — `pnpm-lock.yaml` → pnpm; `yarn.lock` → yarn; `bun.lockb` → bun; default npm.
- **`recommended_hard_wall_minutes`**: scale with project size — count source files (excluding node_modules, vendor, target/, dist/, build/):
  - files < 100 → 60 minutes
  - files 100-1000 → 180 minutes
  - files > 1000 → 300 minutes (default)
  - This is the DEFAULT for Q7.3 — user can still override. (GAP #24 fix.)

### Q0.0 — Setup tier
Standard question from yaml. Sets `$TIER`.

### Q0.1 — Project folder(s)
Free-text. User can paste one path or multiple (newline-separated or comma-separated).

For each path:
- Validate it exists: `[ -d "$path" ]`
- Validate it's a git repo: `git -C "$path" rev-parse --git-dir`
- If either fails, re-ask the specific bad path

Persist as array:
```bash
jq --arg p "$PATH" '.projects += [{"path": $p}]' "$SCAN_JSON" > tmp && mv tmp "$SCAN_JSON"
```

### Q0.2 — Deep scan

For each project in the projects array, run a deep scan. Use parallel `Bash` calls where independent. Persist everything to `$SCAN_JSON` under `.projects[i]`.

**Stack detection** — check for these files in order, first match wins:
```
package.json    → node/ts (check for: react-native, next, vue, angular, electron, svelte, solid, astro, remix, nuxt)
Cargo.toml      → rust
requirements.txt|pyproject.toml|setup.py|Pipfile → python (check for: django, flask, fastapi, pytest)
go.mod          → go
Gemfile         → ruby (check for: rails, sinatra)
composer.json   → php (check for: laravel, symfony)
mix.exs         → elixir (check for: phoenix in deps)
deno.json|deno.jsonc → deno
pom.xml|build.gradle|build.gradle.kts → java/kotlin (check for: spring-boot)
*.csproj|*.sln  → .NET (check for: AspNetCore)
Package.swift   → swift
*.cabal|stack.yaml|package.yaml → haskell
build.zig       → zig
shard.yml       → crystal
dune-project|*.opam → ocaml
build.sbt       → scala
Project.toml    → julia
flake.nix|default.nix → nix (check for: nodejs/python/rust as sub-frameworks)
```

Persist as `.projects[i].stack = "<detected>"` and `.projects[i].framework = "<sub-detection>"`.

**Fallback for unknown stacks:** if none of the above match, set:
```
.projects[i].stack = "unknown"
.projects[i].framework = ""
.projects[i].verify_methods = []
```
Wizard continues — Q5.1 will prompt user for custom verify command. Don't crash. Recipes that need a known stack (e.g. maintenance-bot dep audit) will gracefully skip.

**Test/lint/e2e scripts** (per stack):
- Node: read `package.json:.scripts`, look for `test`, `lint`, `typecheck`, `e2e`. Look for `playwright`/`cypress`/`detox`/`jest` in dependencies.
- Python: look for `pytest.ini`, `pyproject.toml:[tool.pytest]`, `tox.ini`, `.flake8`, `ruff.toml`, `mypy.ini`.
- Go: presence of `_test.go` files. `go vet` always available.
- Rust: `cargo test` always available; check for `clippy.toml`.
- Etc.

Persist as `.projects[i].verify_methods = [{name, command, source}]`.

**GitHub remote:**
```bash
gh repo view --json owner,name,defaultBranchRef,description,visibility,primaryLanguage 2>/dev/null
# or fallback to: git -C "$path" remote get-url origin
```

Persist as `.projects[i].github = {owner, name, default_branch, primary_language, visibility, description}`.

**GitHub user (once, top-level — needed for gh_repo_full template variable):**
```bash
gh api user --jq .login 2>/dev/null   # e.g., "adriankrawczyk"
```

Persist as `$SCAN_JSON.gh_user_login`. Skip silently if `gh auth status` is not OK.

**Recent activity** (last 14d):
```bash
git -C "$path" log --since='14 days ago' --pretty=format:'%H|%ad|%an|%s' --date=short
git -C "$path" branch --sort=-committerdate --format='%(refname:short)|%(committerdate:short)|%(authorname)' | head -20
```

Persist counts + last-commit date.

**User's open PRs:**
```bash
gh pr list --author @me --state open --json number,title,createdAt,updatedAt,isDraft,reviewDecision,reviews 2>/dev/null
```

Persist `.projects[i].user_open_prs = [...]`. Also extract `most_frequent_reviewers` by counting unique reviewer logins.

**Detected env vars** (for verify):
```bash
# .env.example or similar (read keys, NEVER values from real .env)
for f in .env.example .env.template .env.sample; do
  [ -f "$path/$f" ] && grep -oE '^[A-Z][A-Z0-9_]+' "$path/$f"
done
# package.json scripts referencing process.env
node -e 'const pkg=require("'$path'/package.json"); for (const s in (pkg.scripts||{})) console.log(s+": "+pkg.scripts[s])' 2>/dev/null | grep -oE 'process\.env\.[A-Z][A-Z0-9_]+'
```

Persist as `.projects[i].env_vars_needed = [...]`.

**Auth/login indicators** (for Q5.3 trigger):
```bash
grep -rEl 'sign[_-]?in|login|auth|session|jwt' "$path/src" 2>/dev/null | head -5
```

Persist `.projects[i].has_login_flow = true/false`.

**Stale branches:**
```bash
git -C "$path" for-each-ref --sort=committerdate refs/heads/ \
  --format='%(refname:short)|%(committerdate:short)|%(committerdate:relative)' \
  | awk -F'|' '{ cmd="date -u -j -f %Y-%m-%d "$2" +%s 2>/dev/null"; cmd | getline ts; close(cmd); now=systime(); age=(now-ts)/86400; if (age > 30) print $0 }' | head -10
```

Persist count of stale branches.

### Global scan (once, not per-project)

**OS + shell:**
```bash
uname -s; sw_vers -productVersion 2>/dev/null; echo $SHELL
```

Persist `.os`, `.os_version`, `.shell`.

**Existing MCPs:**

**Primary source — `claude mcp list` (Claude Code CLI):**
```bash
claude mcp list 2>/dev/null | sed '/^Checking/d; /^$/d'
# Returns lines like:
#   claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✓ Connected
#   claude.ai Slack: https://mcp.slack.com/mcp - ✓ Connected
#   claude.ai Google Calendar: https://calendarmcp.googleapis.com/mcp/v1 - ! Needs authentication
#   sentry: https://mcp.sentry.dev/mcp (HTTP) - ✓ Connected
#   linear: https://mcp.linear.app/mcp (HTTP) - ✓ Connected
#   serena: serena start-mcp-server --context=claude-code --project-from-cwd - ✓ Connected
#   plugin:context7:context7: npx -y @upstash/context7-mcp - ✓ Connected
#   argent: argent mcp - ✓ Connected
```

Parse format: `<name>: <transport> [- optional flag] - <status>`. Defensive notes:
- MCP names can have spaces ("claude.ai Google Drive"), colons ("plugin:context7:context7"), dots, and other punctuation. Normalize for use in templates: lowercase + `_` for spaces, drop `claude.ai ` prefix and `plugin:<pkg>:` prefix → e.g., `claude.ai Google Drive` becomes `google_drive`.
- Transport can be a URL (HTTP/SSE) OR a shell command (local stdio with args).
- Status indicators: `✓ Connected`, `! Needs authentication`, `✗ Error`, others. Treat anything that isn't `Connected` as unavailable to the night-shift agent at run time.
- Optional `(HTTP)` / `(SSE)` marker may appear between transport and status — ignore it.
- The first line `Checking MCP server health…` is a status banner — skip it.

```bash
# Reference parser (use jq-ready output):
claude mcp list 2>/dev/null \
  | awk '/^Checking/||/^$/{next} { 
      match($0, /[ \t]+- (✓|!|✗)/);
      name = substr($0, 1, RSTART - 1); sub(/:[ \t]*$/, "", name);
      status = substr($0, RSTART + 4);
      printf "{\"raw_name\": %s, \"status\": %s}\n", \
        "\"" name "\"", \
        ("\"" status "\"") 
    }' | jq -s .
```

This is the source of truth for what's available to the night-shift agent at run time. The wizard installs ADDITIONAL MCPs via `claude mcp add` when user wants new ones. After install, re-run `claude mcp list` to confirm.

**Secondary source — Claude Desktop app config (separate, less common for night-shift users):**
```bash
# macOS
CFG_MAC="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
[ -f "$CFG_MAC" ] && jq '.mcpServers | keys' "$CFG_MAC" 2>/dev/null
# Linux
CFG_LINUX="$HOME/.config/Claude/claude_desktop_config.json"
[ -f "$CFG_LINUX" ] && jq '.mcpServers | keys' "$CFG_LINUX" 2>/dev/null
```

If a user has Claude Desktop MCPs that ARE NOT in `claude mcp list`, they're not available to the night-shift agent (which uses Claude Code CLI). Note this discrepancy if observed.

Persist as `.existing_mcps = [...]` (from CLI list, the authoritative source).

Also use the `mcp-registry` MCP if available — it can list every known MCP for install suggestions:
```
mcp__mcp-registry__list_connectors
```

Persist registry catalog as `.available_mcps_in_registry = [...]`.

**Binaries:**
```bash
for bin in git gh jq claude gtimeout terminal-notifier launchctl systemctl caffeinate networksetup nmcli; do
  command -v "$bin" >/dev/null 2>&1 && echo "$bin: present" || echo "$bin: missing"
done
```

Persist as `.binaries = {git: true, gh: true, ...}`.

**Network:**
```bash
ping -c 1 -W 1500 api.github.com >/dev/null 2>&1 && echo "github: reachable"
ping -c 1 -W 1500 api.anthropic.com >/dev/null 2>&1 && echo "anthropic: reachable"
```

Persist as `.network = {github: true, anthropic: true}`.

**Existing scheduled jobs (collision detection):**
```bash
# macOS
ls ~/Library/LaunchAgents/ 2>/dev/null | grep -E 'night|shift|agent'
# Linux
systemctl --user list-timers 2>/dev/null | grep -E 'night|shift|agent'
# Cron
crontab -l 2>/dev/null | grep -E 'night|shift|agent'
```

Persist any conflicts as `.scheduling_conflicts = [...]`.

**Git config (for commits):**
```bash
git config --global user.name
git config --global user.email
```

Persist as `.git_user = {name, email}`.

### Present summary to user (Q0.2 confirmation)

Format compactly, per-project (max 8 lines/project), no jargon. Use the templated summary in `templates/scan-summary.md.template`.

Example output for a React Native project:
```
Your project: my-app
Type: a mobile app (React Native + Expo)
On GitHub: kowalski/my-app (default branch: main)
Last change: 2 days ago
You have 3 open PRs (most often reviewed by: anna_kowalska — 14 reviews in 6 months)
Your machine: Mac (I can wake it up automatically)
Already connected: GitHub, Slack
```

Ask Q0.2. If user picks B (edit), show the full `$SCAN_JSON` content and let them edit answers per field. If C (wrong project), loop back to Q0.1.

### Q0.3 — Install folder

Standard from yaml. Default `~/night-shift-agent/`. Persist as `.install_dir`.

### Q0.4 — GitHub repo decision

Standard from yaml. If user picks A or B (create repo), test that `gh auth status` returns OK first. If not, walk them through `gh auth login` (one-shot — give the exact command).

Persist as `.gh_repo = {create: bool, visibility: "private|public", name: "night-shift-agent"}`.

---

