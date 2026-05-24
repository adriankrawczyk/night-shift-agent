## PHASE 7 — Schedule + resilience

### Q7.1 — Execution location
Standard. Persist `.execution_mode = "local|cloud|both|on_demand"`.

If `cloud` or `both`: print the exact steps to set up claude.ai/code Schedule (see `COORD_PATTERN.md` for the full setup script). Do NOT try to automate cloud scheduling — it requires UI.

If `both`: also load `COORD_PATTERN.md` and configure the dual-write coord (gist + Drive) per its protocol. The generated `run.sh` includes the coordination block (gated on `{{#if multi_machine}}`).

**Wizard side-effect when multi_machine is on:** copy `COORD_PATTERN.md` from the installer dir to `<install_dir>/coord.md` so the night-shift agent can reference the full protocol at runtime (the generated `prompt.md` only inlines the decision logic, not the full state-shape / failure-mode catalog):
```bash
cp "$INSTALLER_DIR/COORD_PATTERN.md" "$INSTALL_DIR/coord.md"
```
For single-machine setups (`execution_mode != both`), skip this — coord.md is dead weight if there's no other runner.

### Q7.2 — Schedule (if not on_demand)
Days (multi-select) + time (24h format). Persist `.schedule = {days, time}`.

**REQUIRED post-Q7.2 derivation step** — split `schedule.time` "HH:MM" into separate hour/minute fields so templates (launchd-routine.plist etc.) can render the integers directly:

```bash
jq '
  .schedule.hour   = ((.schedule.time // "23:55") | split(":")[0] | tonumber)
  | .schedule.minute = ((.schedule.time // "23:55") | split(":")[1] | tonumber)
' "$ANSWERS_JSON" > "$ANSWERS_JSON.tmp" && mv "$ANSWERS_JSON.tmp" "$ANSWERS_JSON"
```

Without this, `launchd-routine.plist.template` renders empty `<integer></integer>` and `plutil -lint` fails.

### Q7.3 — Hard wall
Standard. Persist `.hard_wall_minutes`.

### Q7.4 — Resilience preset (Full only)
Standard. Persist `.resilience = "conservative|balanced|aggressive"`.
(NB: "balanced" here is the **resilience** preset — unrelated to the wizard's two tiers.)

Default if Minimal: "balanced".

---

