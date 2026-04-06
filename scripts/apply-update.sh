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
import json
try:
    h = json.load(open('$HISTORY_PATH'))
    if h: h[-1]['status']='error'; h[-1]['error']='$msg'
    json.dump(h, open('$HISTORY_PATH','w'), indent=2)
except: pass
" 2>/dev/null || true
    echo "[apply-update] ERROR: $msg" >&2
    rm -rf "$WORK_DIR" || true
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

mkdir -p "$WORK_DIR"

# ── Extract version.json first (always small, first file in archive) ─────────
write_status "applying" 8 "Reading bundle metadata…"
tar -xf "$BUNDLE_PATH" -C "$WORK_DIR" version.json 2>/dev/null \
    || fail "Failed to extract version.json from bundle"
[[ -f "$VERSION_JSON_PATH" ]] || fail "version.json not found in bundle"

VERSION=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d.get('version','unknown'))" 2>/dev/null || echo "unknown")
DRY_RUN=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print('yes' if d.get('dry_run') else 'no')" 2>/dev/null || echo "no")
OCI_IMAGE_FILE=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d.get('oci_image_file',''))" 2>/dev/null || echo "")

echo "[apply-update] Bundle version=${VERSION} dry_run=${DRY_RUN} oci=${OCI_IMAGE_FILE:-none}"

# ── Dry run path ─────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "yes" ]]; then
    write_status "applying" 40 "Dry run — simulating update v${VERSION}…"
    echo "[apply-update] DRY RUN — skipping all changes, sleeping 3s"
    sleep 3
    write_status "applying" 90 "Dry run complete, cleaning up…"
    mark_complete "dry_run"
    rm -rf "$WORK_DIR" "$BUNDLE_PATH"
    write_status "idle" 0 "Dry run v${VERSION} applied (no actual changes made)."
    echo "[apply-update] DRY RUN complete for v${VERSION}"
    exit 0
fi

# ── OCI/bootc path ────────────────────────────────────────────────────────────
if [[ -n "$OCI_IMAGE_FILE" ]]; then
    IMAGE_NAME=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d.get('oci_image_name','localhost/inferno-appliance:latest'))" 2>/dev/null || echo "localhost/inferno-appliance:latest")

    # Bundle size check (OCI bundles should be > 100MB)
    BUNDLE_SIZE=$(stat -c%s "$BUNDLE_PATH")
    [[ "$BUNDLE_SIZE" -gt 104857600 ]] || {
        echo "[apply-update] WARNING: OCI bundle is only ${BUNDLE_SIZE} bytes — may be incomplete"
    }

    # Extract OCI image tar (large — streams directly, may take minutes)
    write_status "applying" 15 "Extracting OCI image from bundle (this takes a few minutes)…"
    echo "[apply-update] Extracting ${OCI_IMAGE_FILE} from bundle…"
    tar -xf "$BUNDLE_PATH" -C "$WORK_DIR" "$OCI_IMAGE_FILE" \
        || fail "Failed to extract ${OCI_IMAGE_FILE} from bundle"
    OCI_TAR_PATH="${WORK_DIR}/${OCI_IMAGE_FILE}"
    [[ -f "$OCI_TAR_PATH" ]] || fail "Extracted OCI archive not found at ${OCI_TAR_PATH}"

    # Load OCI image into local container storage
    write_status "applying" 45 "Verifying image integrity (sha256)…"
    EXPECTED_SHA256=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print(d.get('image_sha256',''))" 2>/dev/null || echo "")
    if [[ -n "$EXPECTED_SHA256" ]]; then
        echo "[apply-update] Verifying sha256 of image.tar…"
        ACTUAL_SHA256=$(sha256sum "${OCI_TAR_PATH}" | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            fail "SHA256 mismatch: bundle may be corrupt.\n  expected: ${EXPECTED_SHA256}\n  actual:   ${ACTUAL_SHA256}"
        fi
        echo "[apply-update] sha256 OK: ${ACTUAL_SHA256}"
    else
        echo "[apply-update] WARNING: No image_sha256 in version.json — skipping integrity check"
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
    skopeo copy \
        "${SKOPEO_SRC}" \
        "containers-storage:${IMAGE_NAME}" \
        || fail "skopeo copy failed — check image archive integrity"

    # Switch bootc to the new image
    write_status "applying" 80 "Staging bootc update to ${IMAGE_NAME}…"
    echo "[apply-update] Running bootc switch to ${IMAGE_NAME}…"
    bootc switch --transport containers-storage "${IMAGE_NAME}" \
        || fail "bootc switch failed"

    mark_complete "applied"
    rm -rf "$WORK_DIR" "$BUNDLE_PATH"

    write_status "rebooting" 100 "Update v${VERSION} staged. Rebooting in 5 seconds…"
    echo "[apply-update] SUCCESS — rebooting to apply ${IMAGE_NAME}"
    sleep 5
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
ostree --repo="$OSTREE_REPO" static-delta apply-offline "$DELTA_PATH" \
    || fail "ostree static-delta apply-offline failed"
ostree --repo="$OSTREE_REPO" show "$TO_COMMIT" > /dev/null 2>&1 \
    || fail "Commit ${TO_COMMIT} not found in repo after delta apply"

write_status "applying" 70 "Deploying new commit via rpm-ostree…"
echo "[apply-update] Deploying ${TO_COMMIT}…"
rpm-ostree deploy ":${TO_COMMIT}" || fail "rpm-ostree deploy failed"

mark_complete "applied"
rm -rf "$WORK_DIR" "$BUNDLE_PATH"

write_status "rebooting" 100 "Update applied (v${VERSION}). Rebooting in 5 seconds…"
echo "[apply-update] SUCCESS — rebooting"
sleep 5
systemctl reboot
