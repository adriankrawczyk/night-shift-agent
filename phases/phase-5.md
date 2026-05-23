## PHASE 5 — Verify loop

### Q5.1 — Use detected verification

Show what was scanned (Phase 0). User picks A/B/C/D:
- A: use all
- B: multi-select toggle
- C: free text verify command + success criteria
- D: don't verify (warn)

Persist `.verify_methods = [{name, command, enabled}]`.

### Q5.2 — UI/runtime automation (conditional)

Trigger conditions:
- `project_touches_ui == true` (per the refined detection in Phase 0) AND no MCP-level automation tool connected → ask
- Otherwise skip

**Important distinction (GAP #13):** Playwright as a **test runner** (project has `playwright.config.js`) is DIFFERENT from Playwright **MCP** (controls a browser at agent run time). Both can coexist:
- If project has Playwright test runner: it's already in Q5.1 verify methods, no action needed for that
- If user wants visual verification of patches BEYOND their e2e suite (e.g., checking a screen the e2e suite doesn't cover) → install Playwright MCP

Phrase Q5.2 accordingly:
> Some of what I'd do touches UI behavior. I see you {{ have_playwright_runner ? "already use Playwright for tests — great, I'll use that for verify" : "don't have UI test automation set up yet" }}.
> Do you want me to also drive a real browser/simulator for visual verification of UI patches?
> (This is in ADDITION to your tests — covers cases your e2e suite might miss.)

Options based on stack:
- mobile (RN/native iOS/Android) → suggest Argent
- web (React/Vue/etc with browser DOM) → suggest Playwright MCP (note: separate from the project's Playwright test runner if present)
- both → suggest both

Persist `.ui_automation = "argent|playwright_mcp|both|none"`.

### Q5.3 — Secrets & config

Built from scan's `.projects[].env_vars_needed`. For each:
- Try to determine source (`.env.example` has it, README mentions it, package.json defaults, etc.)
- Present user: vars with detected sources marked ✓, unknowns marked ✗
- Bundled approval (A) for known-source vars
- Per-secret loop for unknowns (paste value / point to file / skip / **auto-generate** for *_SECRET / *_TOKEN patterns)

**Auto-generate pattern (GAP #5 fix):** for unknown secrets whose names match `*_SECRET`, `*_TOKEN`, `*_KEY` AND aren't external-system-identifying (i.e., they don't look like `STRIPE_*`, `OPENAI_*`, `GITHUB_*` — those are external services), offer an extra option:
- (E) Auto-generate a random value (works for local-only test secrets like JWT_SECRET)
- Implementation: `openssl rand -hex 32` for hex; `openssl rand -base64 32` for base64

Per-secret options become:
- A) Paste value here (encrypted at rest)
- B) Point me at a file
- C) Skip this verify
- D) (conditional, only if pattern matches) Auto-generate a random value

Persist as `.secrets_config = {strategy: "auto|env_file|paste|skip|generated", env_file: "...", values: {...}}`.

**Secret storage:**
- Default path: `~/.config/night-shift-agent/secrets.json` chmod 600
- Generated `run.sh` reads this file at run time, sources values into env before invoking the agent
- Cleanup trap in `run.sh` scrubs values from logs

After Q5.3 ends: run a dry-verify (the first verify command from Q5.1) to validate setup. Report success/failure.

---

