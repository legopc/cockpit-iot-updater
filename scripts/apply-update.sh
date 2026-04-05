#!/usr/bin/env bash
# apply-update.sh — apply a Fedora IoT OSTree static delta bundle
# Called by iot-update.service (runs as root, Type=oneshot)
#
# Expects:
#   /var/tmp/iot43-update.iotupdate  — the .iotupdate tar bundle
#   /var/lib/iot-updater/history.json — updated by sidecar with "applying" entry
#
# Dry-run bundles (version.json has "dry_run": true) skip the ostree step
# and complete without rebooting — useful for testing the upload flow.

set -euo pipefail

BUNDLE_PATH="/var/tmp/iot43-update.iotupdate"
DELTA_PATH="/var/tmp/iot43-update.delta"
VERSION_JSON_PATH="/var/tmp/iot43-version.json"
STATUS_PATH="/run/iot-update-status.json"
HISTORY_PATH="/var/lib/iot-updater/history.json"
OSTREE_REPO="/ostree/repo"

write_status() {
    local stage="$1" pct="$2" msg="$3"
    printf '{"stage":"%s","progress_pct":%d,"message":"%s"}\n' \
        "$stage" "$pct" "$msg" > "$STATUS_PATH"
}

fail() {
    local msg="$1"
    write_status "error" 0 "$msg"
    python3 -c "
import json, sys
try:
    h = json.load(open('$HISTORY_PATH'))
    if h: h[-1]['status']='error'; h[-1]['error']='$msg'
    json.dump(h, open('$HISTORY_PATH','w'), indent=2)
except: pass
" 2>/dev/null || true
    echo "[apply-update] ERROR: $msg" >&2
    exit 1
}

mark_complete() {
    local status="$1"
    python3 -c "
import json, time
try:
    h = json.load(open('$HISTORY_PATH'))
    if h:
        h[-1]['status'] = '$status'
        h[-1]['applied_at_complete'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    json.dump(h, open('$HISTORY_PATH', 'w'), indent=2)
except Exception as e:
    print('history update error:', e)
" 2>/dev/null || true
}

# ── Validate bundle ──────────────────────────────────────────────────────────
write_status "applying" 5 "Validating bundle…"

[[ -f "$BUNDLE_PATH" ]] || fail "Bundle not found at $BUNDLE_PATH"

# ── Extract version.json from bundle ─────────────────────────────────────────
write_status "applying" 10 "Extracting bundle…"

tar -xf "$BUNDLE_PATH" -C /var/tmp version.json 2>/dev/null || fail "Failed to extract version.json from bundle"
[[ -f "/var/tmp/version.json" ]] && mv /var/tmp/version.json "$VERSION_JSON_PATH"
[[ -f "$VERSION_JSON_PATH" ]] || fail "version.json not found in bundle"

VERSION=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d.get('version','unknown'))" 2>/dev/null || echo "unknown")
DRY_RUN=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print('yes' if d.get('dry_run') else 'no')" 2>/dev/null || echo "no")

# ── Dry run path ─────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "yes" ]]; then
    write_status "applying" 40 "Dry run — simulating update v${VERSION}…"
    echo "[apply-update] DRY RUN — skipping ostree, sleeping 3s"
    sleep 3
    write_status "applying" 90 "Dry run complete, cleaning up…"
    mark_complete "dry_run"
    rm -f "$BUNDLE_PATH" "$VERSION_JSON_PATH"
    write_status "idle" 0 "Dry run v${VERSION} applied (no actual changes made)."
    echo "[apply-update] DRY RUN complete for v${VERSION}"
    exit 0
fi

# ── Production path ──────────────────────────────────────────────────────────
BUNDLE_SIZE=$(stat -c%s "$BUNDLE_PATH")
[[ "$BUNDLE_SIZE" -gt 1048576 ]] || fail "Bundle too small ($BUNDLE_SIZE bytes) — likely corrupt"

tar -xf "$BUNDLE_PATH" -C /var/tmp update.delta 2>/dev/null || fail "Failed to extract update.delta from bundle"
[[ -f "/var/tmp/update.delta" ]] && mv /var/tmp/update.delta "$DELTA_PATH"
[[ -f "$DELTA_PATH" ]] || fail "update.delta not found in bundle"

TO_COMMIT=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d['to_commit'])" 2>/dev/null) \
    || fail "Cannot read to_commit from version.json"

# ── Apply OSTree static delta ─────────────────────────────────────────────────
write_status "applying" 30 "Applying OSTree static delta (v${VERSION})…"
echo "[apply-update] Applying static delta for commit ${TO_COMMIT}…"

ostree --repo="$OSTREE_REPO" static-delta apply-offline "$DELTA_PATH" \
    || fail "ostree static-delta apply-offline failed"

ostree --repo="$OSTREE_REPO" show "$TO_COMMIT" > /dev/null 2>&1 \
    || fail "Commit $TO_COMMIT not found in repo after delta apply"

# ── Deploy via rpm-ostree ─────────────────────────────────────────────────────
write_status "applying" 70 "Deploying new commit via rpm-ostree…"
echo "[apply-update] Deploying ${TO_COMMIT}…"

rpm-ostree deploy ":${TO_COMMIT}" || fail "rpm-ostree deploy failed"

# ── Mark history as applied ───────────────────────────────────────────────────
mark_complete "applied"

# ── Clean up ──────────────────────────────────────────────────────────────────
rm -f "$BUNDLE_PATH" "$DELTA_PATH" "$VERSION_JSON_PATH"

# ── Reboot ───────────────────────────────────────────────────────────────────
write_status "rebooting" 100 "Update applied (v${VERSION}). Rebooting in 5 seconds…"
echo "[apply-update] SUCCESS — rebooting in 5 seconds"
sleep 5
systemctl reboot


set -euo pipefail

BUNDLE_PATH="/var/tmp/iot43-update.iotupdate"
DELTA_PATH="/var/tmp/iot43-update.delta"
VERSION_JSON_PATH="/var/tmp/iot43-version.json"
STATUS_PATH="/run/iot-update-status.json"
HISTORY_PATH="/var/lib/iot-updater/history.json"
OSTREE_REPO="/ostree/repo"

write_status() {
    local stage="$1" pct="$2" msg="$3"
    printf '{"stage":"%s","progress_pct":%d,"message":"%s"}\n' \
        "$stage" "$pct" "$msg" > "$STATUS_PATH"
}

fail() {
    local msg="$1"
    write_status "error" 0 "$msg"
    # Mark last history entry as error
    python3 -c "
import json, sys
try:
    h = json.load(open('$HISTORY_PATH'))
    if h: h[-1]['status']='error'; h[-1]['error']='$msg'
    json.dump(h, open('$HISTORY_PATH','w'), indent=2)
except: pass
" 2>/dev/null || true
    echo "[apply-update] ERROR: $msg" >&2
    exit 1
}

# ── Validate bundle ──────────────────────────────────────────────────────────
write_status "applying" 5 "Validating bundle…"

[[ -f "$BUNDLE_PATH" ]] || fail "Bundle not found at $BUNDLE_PATH"
BUNDLE_SIZE=$(stat -c%s "$BUNDLE_PATH")
[[ "$BUNDLE_SIZE" -gt 1048576 ]] || fail "Bundle too small ($BUNDLE_SIZE bytes) — likely corrupt"

# ── Extract version.json + delta from bundle ─────────────────────────────────
write_status "applying" 10 "Extracting bundle…"

tar -xf "$BUNDLE_PATH" -C /var/tmp --wildcards \
    "version.json" "update.delta" 2>/dev/null || fail "Failed to extract bundle"

[[ -f "$VERSION_JSON_PATH" || -f "/var/tmp/version.json" ]] || fail "version.json not found in bundle"

# tar may extract to /var/tmp/ directly
[[ -f "/var/tmp/version.json" ]] && mv /var/tmp/version.json "$VERSION_JSON_PATH"
[[ -f "/var/tmp/update.delta" ]] && mv /var/tmp/update.delta "$DELTA_PATH"

[[ -f "$DELTA_PATH" ]] || fail "update.delta not found in bundle"

# Read target commit from version.json
TO_COMMIT=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d['to_commit'])" 2>/dev/null) \
    || fail "Cannot read to_commit from version.json"

VERSION=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d.get('version','unknown'))" 2>/dev/null || echo "unknown")

# ── Apply OSTree static delta ─────────────────────────────────────────────────
write_status "applying" 30 "Applying OSTree static delta (v${VERSION})…"
echo "[apply-update] Applying static delta for commit ${TO_COMMIT}…"

ostree --repo="$OSTREE_REPO" static-delta apply-offline "$DELTA_PATH" \
    || fail "ostree static-delta apply-offline failed"

# Verify the commit arrived
ostree --repo="$OSTREE_REPO" show "$TO_COMMIT" > /dev/null 2>&1 \
    || fail "Commit $TO_COMMIT not found in repo after delta apply"

# ── Deploy via rpm-ostree ─────────────────────────────────────────────────────
write_status "applying" 70 "Deploying new commit via rpm-ostree…"
echo "[apply-update] Deploying ${TO_COMMIT}…"

rpm-ostree deploy ":${TO_COMMIT}" || fail "rpm-ostree deploy failed"

# ── Mark history as applied ───────────────────────────────────────────────────
python3 -c "
import json, time
try:
    h = json.load(open('$HISTORY_PATH'))
    if h:
        h[-1]['status'] = 'applied'
        h[-1]['applied_at_complete'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    json.dump(h, open('$HISTORY_PATH', 'w'), indent=2)
except Exception as e:
    print('history update error:', e)
" 2>/dev/null || true

# ── Clean up ──────────────────────────────────────────────────────────────────
rm -f "$BUNDLE_PATH" "$DELTA_PATH" "$VERSION_JSON_PATH"

# ── Reboot ───────────────────────────────────────────────────────────────────
write_status "rebooting" 100 "Update applied (v${VERSION}). Rebooting in 5 seconds…"
echo "[apply-update] SUCCESS — rebooting in 5 seconds"
sleep 5
systemctl reboot
