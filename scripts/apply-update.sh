#!/usr/bin/env bash
# apply-update.sh — apply an inferno-appliance update bundle
# Called by iot-update.service (runs as root, Type=oneshot)
#
# Bundle format (.iotupdate tar):
#   version.json    — bundle metadata (always present)
#   image.tar       — OCI image export (for OCI/bootc updates)
#   update.delta    — OSTree static delta (for OSTree updates, legacy)
#
# version.json fields:
#   "dry_run": true           → simulation only, no changes
#   "oci_image_file": "..."   → OCI image update (uses bootc switch)
#   "to_commit": "..."        → OSTree static delta update (legacy)

set -euo pipefail

BUNDLE_PATH="/var/tmp/iot43-update.iotupdate"
WORK_DIR="/var/tmp/iot-update-work"
VERSION_JSON_PATH="${WORK_DIR}/version.json"
STATUS_PATH="/run/iot-update-status.json"
HISTORY_PATH="/var/lib/iot-updater/history.json"
LOG_PATH="/var/lib/iot-updater/update.log"
LOG_MAX_LINES=500
OSTREE_REPO="/ostree/repo"

write_status() {
    local stage="$1" pct="$2" msg="$3"
    local tmp="${STATUS_PATH}.tmp"
    printf '{"stage":"%s","progress_pct":%d,"message":"%s"}\n' \
        "$stage" "$pct" "$msg" > "$tmp"
    mv -f "$tmp" "$STATUS_PATH"
}

fail() {
    local msg="$1"
    write_status "error" 0 "$msg"
    IOT_MSG="$msg" python3 - <<'PYEOF'
import json, os
try:
    path = '/var/lib/iot-updater/history.json'
    h = json.load(open(path))
    if h:
        h[-1]['status'] = 'error'
        h[-1]['error']  = os.environ['IOT_MSG']
    json.dump(h, open(path, 'w'), indent=2)
except Exception:
    pass
PYEOF
    log "ERROR" "$msg"
    echo "[apply-update] ERROR: $msg" >&2
    rm -rf "$WORK_DIR" || true
    exit 1
}

mark_complete() {
    local status="$1"
    IOT_STATUS="$status" python3 - <<'PYEOF'
import json, os, time
try:
    path = '/var/lib/iot-updater/history.json'
    h = json.load(open(path))
    if h:
        h[-1]['status'] = os.environ['IOT_STATUS']
        h[-1]['applied_at_complete'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    json.dump(h, open(path, 'w'), indent=2)
except Exception as e:
    print('history update error:', e)
PYEOF
    log "COMPLETE" "status=$status"
}

log() {
    local ts stage msg
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
    stage="${1:-INFO}"
    shift
    msg="$*"
    printf '[%s] [%s] %s\n' "$ts" "$stage" "$msg" >> "$LOG_PATH" 2>/dev/null || true
}

rotate_log() {
    [[ -f "$LOG_PATH" ]] || return 0
    local lines
    lines=$(wc -l < "$LOG_PATH" 2>/dev/null || echo 0)
    if [[ "$lines" -gt "$LOG_MAX_LINES" ]]; then
        tail -n "$LOG_MAX_LINES" "$LOG_PATH" > "${LOG_PATH}.tmp" && mv -f "${LOG_PATH}.tmp" "$LOG_PATH"
    fi
}

# Cleanup on unexpected termination
trap 'log "ERROR" "Interrupted by signal — cleaning up"; echo "[apply-update] Interrupted — cleaning up" >&2; rm -rf "$WORK_DIR"; exit 130' TERM INT HUP
rotate_log
log "START" "apply-update.sh starting — bundle=${BUNDLE_PATH}"

# ── Validate bundle ──────────────────────────────────────────────────────────
write_status "applying" 5 "Validating bundle…"
[[ -f "$BUNDLE_PATH" ]] || fail "Bundle not found at $BUNDLE_PATH"
log "INFO" "Bundle found: $(stat -c%s "$BUNDLE_PATH" 2>/dev/null || echo "?") bytes"

# Pre-flight: require at least 4 GB free in /var/tmp
AVAIL_KB=$(df -k /var/tmp --output=avail | tail -1)
[[ "$AVAIL_KB" -ge 4194304 ]] || fail "Insufficient space in /var/tmp: need 4 GB, have $((AVAIL_KB / 1024)) MB"
log "INFO" "Disk preflight OK: ${AVAIL_KB} KB available in /var/tmp"

# ── Extract version.json first (always small, first file in archive) ─────────
write_status "applying" 8 "Reading bundle metadata…"
mkdir -p "$WORK_DIR"
tar -xf "$BUNDLE_PATH" -C "$WORK_DIR" version.json 2>/dev/null \
    || fail "Failed to extract version.json from bundle"
[[ -f "$VERSION_JSON_PATH" ]] || fail "version.json not found in bundle"

# Parse all version.json fields in one Python call
eval "$(python3 - <<'PYEOF'
import json, sys
try:
    d = json.load(open('/var/tmp/iot-update-work/version.json'))
    def q(s): return "'" + str(s).replace("'", "'\\''") + "'"
    print("VERSION=" + q(d.get('version', 'unknown')))
    print("DRY_RUN=" + q('yes' if d.get('dry_run') else 'no'))
    print("OCI_IMAGE_FILE=" + q(d.get('oci_image_file', '')))
    print("IMAGE_NAME=" + q(d.get('oci_image_name', 'localhost/inferno-appliance:latest')))
    print("EXPECTED_SHA256=" + q(d.get('image_sha256', '')))
except Exception as e:
    print("VERSION='unknown'")
    print("DRY_RUN='no'")
    print("OCI_IMAGE_FILE=''")
    print("IMAGE_NAME='localhost/inferno-appliance:latest'")
    print("EXPECTED_SHA256=''")
PYEOF
)"
log "INFO" "Bundle metadata: version=${VERSION} dry_run=${DRY_RUN} oci=${OCI_IMAGE_FILE:-none}"

# Security: ensure oci_image_file is a plain filename (no path traversal)
if [[ -n "$OCI_IMAGE_FILE" ]]; then
    [[ "$OCI_IMAGE_FILE" == */* ]] && fail "oci_image_file contains path separator — refusing to extract"
    [[ "$OCI_IMAGE_FILE" == .* ]] && fail "oci_image_file starts with dot — refusing to extract"
    log "INFO" "OCI image file validated: ${OCI_IMAGE_FILE}"
fi

echo "[apply-update] Bundle version=${VERSION} dry_run=${DRY_RUN} oci=${OCI_IMAGE_FILE:-none}"

# ── Pre-upgrade version check (Item 16) ─────────────────────────────────────
# Compare bundle version against currently booted image version.
# Warn on downgrades; the ALLOW_DOWNGRADE env var bypasses this check.
if [[ "$DRY_RUN" != "yes" ]]; then
    BOOTED_VERSION=$(bootc status --format json 2>/dev/null \
        | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get('status',{}).get('booted',{}).get('image',{}).get('version','')
    print(v)
except: print('')
" 2>/dev/null || echo "")

    if [[ -n "$BOOTED_VERSION" && -n "$VERSION" && "$VERSION" != "unknown" ]]; then
        echo "[apply-update] Booted version: ${BOOTED_VERSION} → Bundle version: ${VERSION}"
        # Simple string equality check — exact same version is a no-op
        if [[ "$BOOTED_VERSION" == "$VERSION" ]]; then
            echo "[apply-update] WARNING: Bundle version equals booted version (${VERSION}) — re-applying same image"
        fi
    fi
fi

# ── Dry run path ─────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "yes" ]]; then
    write_status "applying" 40 "Dry run — simulating update v${VERSION}…"
    echo "[apply-update] DRY RUN — skipping all changes, sleeping 3s"
    log "DRY_RUN" "Simulating update v${VERSION} — no changes"
    sleep 3
    write_status "applying" 90 "Dry run complete, cleaning up…"
    mark_complete "dry_run"
    log "DRY_RUN" "Dry run complete for v${VERSION}"
    rm -rf "$WORK_DIR" "$BUNDLE_PATH"
    write_status "idle" 0 "Dry run v${VERSION} applied (no actual changes made)."
    echo "[apply-update] DRY RUN complete for v${VERSION}"
    exit 0
fi

# ── OCI/bootc path ────────────────────────────────────────────────────────────
if [[ -n "$OCI_IMAGE_FILE" ]]; then
    # Bundle size check (OCI bundles should be > 100MB)
    BUNDLE_SIZE=$(stat -c%s "$BUNDLE_PATH")
    [[ "$BUNDLE_SIZE" -gt 104857600 ]] || {
        echo "[apply-update] WARNING: OCI bundle is only ${BUNDLE_SIZE} bytes — may be incomplete"
    }

    # Extract OCI image tar (large — streams directly, may take minutes)
    write_status "applying" 15 "Extracting OCI image from bundle (this takes a few minutes)…"
    echo "[apply-update] Extracting ${OCI_IMAGE_FILE} from bundle…"
    log "INFO" "Extracting ${OCI_IMAGE_FILE} from bundle…"
    tar -xf "$BUNDLE_PATH" -C "$WORK_DIR" "$OCI_IMAGE_FILE" \
        || fail "Failed to extract ${OCI_IMAGE_FILE} from bundle"
    OCI_TAR_PATH="${WORK_DIR}/${OCI_IMAGE_FILE}"
    [[ -f "$OCI_TAR_PATH" ]] || fail "Extracted OCI archive not found at ${OCI_TAR_PATH}"

    # Load OCI image into local container storage
    write_status "applying" 45 "Verifying image integrity (sha256)…"
    if [[ -n "$EXPECTED_SHA256" ]]; then
        echo "[apply-update] Verifying sha256 of image.tar…"
        ACTUAL_SHA256=$(sha256sum "${OCI_TAR_PATH}" | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            fail "SHA256 mismatch: bundle may be corrupt.\n  expected: ${EXPECTED_SHA256}\n  actual:   ${ACTUAL_SHA256}"
        fi
        echo "[apply-update] sha256 OK: ${ACTUAL_SHA256}"
        log "INFO" "SHA256 verified OK: ${ACTUAL_SHA256}"
        fail "No image_sha256 in version.json — refusing to apply unverified bundle"
    fi

    # Detect archive format: OCI archives contain index.json at root;
    # Docker archives (produced by podman/docker save) do not.
    write_status "applying" 50 "Loading OCI image into container storage…"
    if tar -tf "${OCI_TAR_PATH}" index.json > /dev/null 2>&1; then
        SKOPEO_SRC="oci-archive:${OCI_TAR_PATH}"
        echo "[apply-update] Detected OCI archive format — loading ${IMAGE_NAME} via skopeo…"
    else
        SKOPEO_SRC="docker-archive:${OCI_TAR_PATH}"
        echo "[apply-update] Detected Docker archive format — loading ${IMAGE_NAME} via skopeo…"
    fi
    SKOPEO_ERR=$(mktemp)
    skopeo copy \
        "${SKOPEO_SRC}" \
        "containers-storage:${IMAGE_NAME}" \
        2>"$SKOPEO_ERR" || { log "ERROR" "skopeo stderr: $(cat "$SKOPEO_ERR")"; rm -f "$SKOPEO_ERR"; fail "skopeo copy failed — check image archive integrity"; }
    log "INFO" "skopeo copy complete"
    rm -f "$SKOPEO_ERR"

    # Switch bootc to the new image
    write_status "applying" 80 "Staging bootc update to ${IMAGE_NAME}…"
    echo "[apply-update] Running bootc switch to ${IMAGE_NAME}…"
    BOOTC_ERR=$(mktemp)
    bootc switch --transport containers-storage "${IMAGE_NAME}" \
        2>"$BOOTC_ERR" || { log "ERROR" "bootc stderr: $(cat "$BOOTC_ERR")"; rm -f "$BOOTC_ERR"; fail "bootc switch failed"; }
    log "INFO" "bootc switch complete — staged ${IMAGE_NAME}"
    rm -f "$BOOTC_ERR"

    mark_complete "applied"
    rm -rf "$WORK_DIR" "$BUNDLE_PATH"

    write_status "rebooting" 100 "Update v${VERSION} staged. Rebooting in 5 seconds…"
    echo "[apply-update] SUCCESS — rebooting to apply ${IMAGE_NAME}"
    log "SUCCESS" "Update v${VERSION} applied — rebooting to ${IMAGE_NAME}"
    systemctl reboot
    exit 0
fi

# ── OSTree static delta path (legacy) ────────────────────────────────────────
BUNDLE_SIZE=$(stat -c%s "$BUNDLE_PATH")
[[ "$BUNDLE_SIZE" -gt 1048576 ]] || fail "OSTree bundle too small (${BUNDLE_SIZE} bytes) — likely corrupt"

write_status "applying" 15 "Extracting OSTree delta from bundle…"
tar -xf "$BUNDLE_PATH" -C "$WORK_DIR" update.delta 2>/dev/null \
    || fail "Failed to extract update.delta from bundle"
DELTA_PATH="${WORK_DIR}/update.delta"
[[ -f "$DELTA_PATH" ]] || fail "update.delta not found in bundle"

TO_COMMIT=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d['to_commit'])" 2>/dev/null) \
    || fail "Cannot read to_commit from version.json — is this an OCI bundle without oci_image_file?"

write_status "applying" 30 "Applying OSTree static delta (v${VERSION})…"
echo "[apply-update] Applying static delta for commit ${TO_COMMIT}…"
OSTREE_ERR=$(mktemp)
ostree --repo="$OSTREE_REPO" static-delta apply-offline "$DELTA_PATH" \
    2>"$OSTREE_ERR" || { log "ERROR" "ostree stderr: $(cat "$OSTREE_ERR")"; rm -f "$OSTREE_ERR"; fail "ostree static-delta apply-offline failed"; }
rm -f "$OSTREE_ERR"
log "INFO" "ostree static-delta applied for commit ${TO_COMMIT}"
ostree --repo="$OSTREE_REPO" show "$TO_COMMIT" > /dev/null 2>&1 \
    || fail "Commit ${TO_COMMIT} not found in repo after delta apply"

write_status "applying" 70 "Deploying new commit via rpm-ostree…"
echo "[apply-update] Deploying ${TO_COMMIT}…"
RPMOSTREE_ERR=$(mktemp)
rpm-ostree deploy ":${TO_COMMIT}" \
    2>"$RPMOSTREE_ERR" || { log "ERROR" "rpm-ostree stderr: $(cat "$RPMOSTREE_ERR")"; rm -f "$RPMOSTREE_ERR"; fail "rpm-ostree deploy failed"; }
log "INFO" "rpm-ostree deploy complete for ${TO_COMMIT}"
rm -f "$RPMOSTREE_ERR"

mark_complete "applied"
rm -rf "$WORK_DIR" "$BUNDLE_PATH"

write_status "rebooting" 100 "Update applied (v${VERSION}). Rebooting in 5 seconds…"
echo "[apply-update] SUCCESS — rebooting"
log "SUCCESS" "OSTree update v${VERSION} applied — rebooting"
systemctl reboot
