## PHASE 6 — Patch delivery + trust

### Q6.1 — Trust toggles

**REQUIRED pre-Q6.1 derivation step:** check if ANY project in scan has a GitHub remote.

```bash
HAS_REMOTE=$(jq '[.projects[]?.github | select(. != null)] | length > 0' "$SCAN_JSON")
jq --argjson h "$HAS_REMOTE" '.has_github_remote = $h' "$ANSWERS_JSON" > "$ANSWERS_JSON.tmp" && mv "$ANSWERS_JSON.tmp" "$ANSWERS_JSON"
```

Filter Q6.1 options dynamically:
- `disk` (always on, required) — always shown
- `pr` (optional) — only shown if `has_github_remote == true`
- `merge` (optional) — only shown if `has_github_remote == true`

If `has_github_remote == false`, skip Q6.1 entirely and persist `.patch_delivery = ["disk"]` with a one-line user notice: "No GitHub remote detected — patches will be delivered to disk only. To enable PR delivery later, add a remote and re-run the wizard."

Persist `.patch_delivery = ["disk", "pr"]` (etc., per user selection).

### Q6.2 — Base branch (if pr or merge)

**Skip if `has_github_remote == false`.** Otherwise:

Default: project's `default_branch` from Phase-0 scan (`$SCAN_JSON.projects[0].default_branch`).
- If scan failed to detect (e.g. brand-new repo with no remote, no refs), fall back to `main`.
- Allow user override.

Persist `.base_branch`.

### Q6.3 — Commit style (Full tier)
Standard. Persist `.commit_style`.

---

