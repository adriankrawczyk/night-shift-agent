## PHASE 6 — Patch delivery + trust

### Q6.1 — Trust toggles
Multi-select:
- `disk` (always on, required)
- `pr` (optional)
- `merge` (optional)

Persist `.patch_delivery = ["disk", "pr"]`.

### Q6.2 — Base branch (if pr or merge)
Default: project's `default_branch` from scan. Allow override.

Persist `.base_branch`.

### Q6.3 — Commit style (Full tier)
Standard. Persist `.commit_style`.

---

