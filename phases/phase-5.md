## PHASE 5 — Verify loop

### Q5.1 — Use detected verification

Show what was scanned (Phase 0). User picks A/B/C/D:
- A: use all
- B: multi-select toggle
- C: free text verify command + success criteria
- D: don't verify (warn)

Persist `.verify_methods = [{name, command, enabled}]`.

### Q5.2 — UI/runtime automation

**Always ask** (Minimal + Full). Skip ONLY if `has_ui_automation == true` (user already has Playwright MCP, Argent, or computer-use connected — no need to re-pick).

**When skipped, seed `.ui_automation` from detection** (so templates don't render `none`):
```bash
if [[ "$(jq -r '.has_ui_automation' "$ANSWERS_JSON")" == "true" ]]; then
  # First-found-wins ordering: argent > playwright > computer_use
  if jq -e '.existing_mcps | index("argent")' "$SCAN_JSON" >/dev/null; then
    UI_TOOL="argent"
  elif jq -e '.existing_mcps | any(. == "playwright" or . == "playwright_mcp")' "$SCAN_JSON" >/dev/null; then
    UI_TOOL="playwright"
  elif jq -e '.existing_mcps | index("computer_use")' "$SCAN_JSON" >/dev/null; then
    UI_TOOL="computer_use"
  else
    UI_TOOL="none"  # shouldn't reach this — has_ui_automation was true
  fi
  jq --arg t "$UI_TOOL" '.ui_automation = $t' "$ANSWERS_JSON" > "$ANSWERS_JSON.tmp" && mv "$ANSWERS_JSON.tmp" "$ANSWERS_JSON"
fi
```

UI automation is universal — it's not just for web/RN projects. Use cases the wizard should NOT gate out:
- Backend service whose admin panel is a desktop Electron app (computer-use)
- CLI tool whose verify needs Photoshop / Figma / external Mac app (computer-use)
- Mobile app (Argent)
- Web app (Playwright MCP)

**Important distinction (GAP #13):** Playwright as a **test runner** (project has `playwright.config.js`) is DIFFERENT from Playwright **MCP** (controls a browser at agent run time). Both can coexist:
- If project has Playwright test runner: it's already in Q5.1 verify methods, no action needed for that
- If user wants visual verification of patches BEYOND their e2e suite → install Playwright MCP via Q5.2

Phrase Q5.2:
> To verify patches actually work in a running UI, I can drive a real browser, mobile simulator, or any desktop app. Which do you want me to set up? (Pick any combination, or none.)

Single-select (one tool per verify-loop keeps orchestration simple). Options:
- **Argent** (iOS / Android simulator / emulator control)
- **Playwright** (web browser automation)
- **Claude computer-use** (any visible app on the user's Mac — Electron, native, browser-as-app; universal but slower)
- **None** (verify with tests only)

Persist `.ui_automation = "argent|playwright|computer_use|none"`.

**Derive `tester_flow`** (consumed by `subagent-tester.md.template` to render the correct discovery + interaction steps per platform). One of:
- `rn_argent` — argent + React Native (stack=react-native OR framework=expo OR primary project has `react-native` dependency)
- `ios_argent` — argent + native iOS (stack=swift / objective-c, framework includes `ios-native`, project has `*.xcodeproj` / `Package.swift` for iOS)
- `android_argent` — argent + native Android (stack=kotlin / java, framework includes `android-native`, project has `app/build.gradle*` + `AndroidManifest.xml`)
- `web_playwright` — playwright (any stack with browser DOM)
- `desktop_computer_use` — computer_use (universal fallback)

Derivation:
```bash
case "$(jq -r '.ui_automation' "$ANSWERS_JSON")" in
  argent)
    P0_STACK=$(jq -r '.projects[0].stack' "$ANSWERS_JSON")
    P0_FW=$(jq -r '.projects[0].framework' "$ANSWERS_JSON")
    case "$P0_STACK:$P0_FW" in
      react-native:*|*:expo|*:react-native) FLOW="rn_argent" ;;
      swift:*|objective-c:*|*:ios-native)   FLOW="ios_argent" ;;
      kotlin:*|java:*|*:android-native)     FLOW="android_argent" ;;
      *) FLOW="rn_argent" ;;  # fallback for legacy "argent assumed RN" installs
    esac ;;
  playwright)    FLOW="web_playwright" ;;
  computer_use)  FLOW="desktop_computer_use" ;;
  *)             FLOW="" ;;  # no tester subagent will be rendered
esac
jq --arg f "$FLOW" '.tester_flow = $f' "$ANSWERS_JSON" > "$ANSWERS_JSON.tmp" && mv "$ANSWERS_JSON.tmp" "$ANSWERS_JSON"
```

**Recommendation overlay** (additive hint, not a gate — surface in option labels):
- If scan detected a mobile project (RN / native iOS / native Android) → prefix Argent option with "(recommended for your stack)"
- If scan detected web (React/Vue/Svelte/Angular with browser DOM) → prefix Playwright option with "(recommended for your stack)"
- computer-use is always selectable regardless of stack — it's the universal fallback

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

