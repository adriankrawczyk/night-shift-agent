## PHASE 7 — Schedule + resilience

### Q7.1 — Execution location
Standard. Persist `.execution_mode = "local|cloud|both|on_demand"`.

If `cloud` or `both`: print the exact steps to set up claude.ai/code Schedule (see `COORD_PATTERN.md` for the full setup script). Do NOT try to automate cloud scheduling — it requires UI.

If `both`: also load `COORD_PATTERN.md` and configure the dual-write coord (gist + Drive) per its protocol. The generated `run.sh` includes the coordination block (gated on `{{#if multi_machine}}`).

### Q7.2 — Schedule (if not on_demand)
Days (multi-select) + time (24h format). Persist `.schedule = {days, time}`.

### Q7.3 — Hard wall
Standard. Persist `.hard_wall_minutes`.

### Q7.4 — Resilience tier (Full only)
Standard. Persist `.resilience = "conservative|balanced|aggressive"`.

Default if Minimal/Balanced: "balanced".

---

