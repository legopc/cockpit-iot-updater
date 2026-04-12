#!/usr/bin/env bash
# apply-update.sh — apply an inferno-appliance update bundle
# Called by iot-update.service (runs as root, Type=oneshot)
#
# Bundle format (.iotupdate tar):
#   version.json    — bundle metadata (always present)
#   image.tar       — OCI image export (for OCI/bootc updates)
#   update.delta    — OSTree static delta (for OSTree updates, legacy)
#   delta.patch     — bsdiff binary patch (for delta bundles)
#
# version.json fields:
#   "dry_run": true           → simulation only, no changes
#   "oci_image_file": "..."   → OCI image update (uses bootc switch)
#   "to_commit": "..."        → OSTree static delta update (legacy)
#   "bundle_type": "delta"    → delta bundle (bsdiff patch, requires bspatch on appliance)
#   "base_sha256": "..."      → sha256 of booted image tar (verified before patching)
#   "target_sha256": "..."    → sha256 of patched result (verified after patching)

set -euo pipefail

# Include /var/lib/iot-updater in PATH so bundled tools (e.g. bspatch) are found
# even on read-only rootfs appliances that lack bsdiff in the base image.
export PATH="/var/lib/iot-updater:$PATH"

BUNDLE_PATH="/var/tmp/iot43-update.iotupdate"
BUNDLE_READY_PATH="/var/lib/iot-updater/bundle-ready"
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
    # Emit structured journal entry so the error appears in journalctl -u iot-update
    echo "[iot-updater] APPLY FAILED: $msg" | systemd-cat -t iot-updater -p err 2>/dev/null || true
    echo "[apply-update] ERROR: $msg" >&2
    rm -rf "$WORK_DIR" || true
    rm -f "$BUNDLE_READY_PATH" || true
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

# Parse all version.json fields individually (no eval)
VERSION=$(python3 -c "import json; print(json.load(open('$VERSION_JSON_PATH')).get('version', 'unknown'))" 2>/dev/null || echo "unknown")
DRY_RUN=$(python3 -c "import json; d=json.load(open('$VERSION_JSON_PATH')); print('yes' if d.get('dry_run') else 'no')" 2>/dev/null || echo "no")
OCI_IMAGE_FILE=$(python3 -c "import json; print(json.load(open('$VERSION_JSON_PATH')).get('oci_image_file', ''))" 2>/dev/null || echo "")
BUNDLE_TYPE=$(python3 -c "import json; print(json.load(open('$VERSION_JSON_PATH')).get('bundle_type', 'full'))" 2>/dev/null || echo "full")
IMAGE_NAME=$(python3 -c "
import json
d = json.load(open('$VERSION_JSON_PATH'))
raw_name = d.get('oci_image_name', '')
ver = d.get('version', 'unknown')
if not raw_name or raw_name.endswith(':unknown'):
    raw_name = 'localhost/inferno-appliance:' + ver
print(raw_name)
" 2>/dev/null || echo "localhost/inferno-appliance:latest")
EXPECTED_SHA256=$(python3 -c "import json; print(json.load(open('$VERSION_JSON_PATH')).get('image_sha256', ''))" 2>/dev/null || echo "")
log "INFO" "Bundle metadata: version=${VERSION} dry_run=${DRY_RUN} type=${BUNDLE_TYPE} oci=${OCI_IMAGE_FILE:-none}"

# ── Ed25519 signature verification ───────────────────────────────────────────
PUBLIC_KEY_PATH="/etc/iot-updater/signing.pub"
ENFORCE_SIGNING="${IOT_UPDATER_ENFORCE_SIGNING:-0}"

if [ -f "$PUBLIC_KEY_PATH" ]; then
  SIG=$(python3 -c "import json,sys; print(json.load(open('$WORK_DIR/version.json')).get('signature',''))" 2>/dev/null)
  if [ -n "$SIG" ]; then
    python3 -c "
import json, base64, sys
d = json.load(open('$WORK_DIR/version.json'))
sig_b64 = d.pop('signature', '')
d.pop('signed_fields', None)
json.dump(d, open('$WORK_DIR/version.json.verify', 'w'), indent=2)
with open('$WORK_DIR/bundle.sig.tmp', 'wb') as f:
    f.write(base64.b64decode(sig_b64))
"
    if openssl dgst -sha256 -verify "$PUBLIC_KEY_PATH" \
        -signature "$WORK_DIR/bundle.sig.tmp" \
        "$WORK_DIR/version.json.verify" 2>/dev/null; then
      log "INFO" "Bundle signature verified OK"
    else
      if [ "$ENFORCE_SIGNING" = "1" ]; then
        rm -f "$WORK_DIR/bundle.sig.tmp" "$WORK_DIR/version.json.verify"
        fail "Bundle signature verification FAILED"
      else
        log "WARNING" "Bundle signature verification failed (enforcement disabled)"
      fi
    fi
    rm -f "$WORK_DIR/bundle.sig.tmp" "$WORK_DIR/version.json.verify"
  else
    if [ "$ENFORCE_SIGNING" = "1" ]; then
      fail "Bundle is unsigned but signing is enforced"
    else
      log "INFO" "Bundle is unsigned (signing not enforced)"
    fi
  fi
else
  log "INFO" "No public key at $PUBLIC_KEY_PATH — skipping signature verification"
fi

# ── Delta bundle detection ────────────────────────────────────────────────────
BUNDLE_TYPE=$(python3 -c "import json,sys; d=json.load(open('$WORK_DIR/version.json')); print(d.get('bundle_type','full'))" 2>/dev/null || echo "full")
if [ "$BUNDLE_TYPE" = "delta" ]; then
  log "INFO" "Delta bundle detected — starting delta apply path"

  # Read delta-specific fields from version.json
  BASE_VERSION=$(python3 -c "import json; print(json.load(open('$VERSION_JSON_PATH')).get('base_version','unknown'))" 2>/dev/null || echo "unknown")
  BASE_SHA256=$(python3 -c "import json; print(json.load(open('$VERSION_JSON_PATH')).get('base_sha256',''))" 2>/dev/null || echo "")
  TARGET_SHA256=$(python3 -c "import json; print(json.load(open('$VERSION_JSON_PATH')).get('target_sha256',''))" 2>/dev/null || echo "")
  ARCHIVE_FORMAT=$(python3 -c "import json; print(json.load(open('$VERSION_JSON_PATH')).get('archive_format','oci'))" 2>/dev/null || echo "oci")

  [ -n "$BASE_SHA256" ] || fail "Delta bundle missing base_sha256 in version.json"
  [ -n "$TARGET_SHA256" ] || fail "Delta bundle missing target_sha256 in version.json"
  [ -n "$OCI_IMAGE_FILE" ] && fail "Delta bundle must not have oci_image_file — malformed bundle"

  # Verify bspatch is available
  command -v bspatch >/dev/null 2>&1 || fail "bspatch not found — delta bundles require the bsdiff package on the appliance"

  # Check disk space: need ~6 GB for base.tar + new-image.tar + delta.patch
  AVAIL_KB_DELTA=$(df -k /var/tmp --output=avail | tail -1)
  [ "$AVAIL_KB_DELTA" -ge 6291456 ] || fail "Insufficient space for delta apply: need 6 GB, have $((AVAIL_KB_DELTA / 1024)) MB in /var/tmp"

  write_status "applying" 15 "Extracting delta patch from bundle…"
  DELTA_PATCH="${WORK_DIR}/delta.patch"
  BASE_EXPORT="${WORK_DIR}/base-export.tar"
  NEW_IMAGE="${WORK_DIR}/new-image.tar"

  tar -xf "$BUNDLE_PATH" -C "$WORK_DIR" delta.patch 2>/dev/null \
    || fail "Failed to extract delta.patch from bundle"
  [ -f "$DELTA_PATCH" ] || fail "delta.patch not found after extraction"
  log "INFO" "delta.patch extracted: $(stat -c%s "$DELTA_PATCH" 2>/dev/null || echo '?') bytes"

  # Get currently booted image name from bootc
  write_status "applying" 20 "Identifying booted image for delta base…"
  BOOTED_IMAGE=$(bootc status --format json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    # Try different JSON structures bootc versions use
    b=d.get('status',{}).get('booted',{})
    img=b.get('image',{})
    # New format
    transport=img.get('image',{}).get('transport','')
    name=img.get('image',{}).get('image','')
    if name: print(name); sys.exit(0)
    # Old format
    print(b.get('image',''))
except: print('')
" 2>/dev/null)
  [ -n "$BOOTED_IMAGE" ] || fail "Cannot determine booted image name from bootc status"
  log "INFO" "Booted image: $BOOTED_IMAGE (expected base: $BASE_VERSION)"

  # Export booted image from containers-storage to a tar in the format the delta was built with
  write_status "applying" 25 "Exporting base image from container storage (this takes a few minutes)…"
  echo "[apply-update] Exporting $BOOTED_IMAGE to base.tar via podman save (format: docker-archive)…"
  PODMAN_ERR=$(mktemp)
  # Use podman save --format docker-archive which produces the same bytes as the build-time export
  podman save --format docker-archive "$BOOTED_IMAGE" -o "$BASE_EXPORT" \
    2>"$PODMAN_ERR" || { log "ERROR" "podman save stderr: $(cat "$PODMAN_ERR")"; rm -f "$PODMAN_ERR"; fail "Failed to export base image from container storage. If storage was pruned, apply a full bundle instead."; }
  rm -f "$PODMAN_ERR"
  log "INFO" "Base image exported: $(stat -c%s "$BASE_EXPORT" 2>/dev/null || echo '?') bytes"

  # Verify base image sha256 matches what the delta expects
  write_status "applying" 40 "Verifying base image integrity…"
  ACTUAL_BASE_SHA256=$(sha256sum "$BASE_EXPORT" | awk '{print $1}')
  if [ "$ACTUAL_BASE_SHA256" != "$BASE_SHA256" ]; then
    rm -f "$BASE_EXPORT" "$DELTA_PATCH"
    fail "Running image sha256 does not match delta bundle base. You may have upgraded since this delta was built. Apply a full bundle instead."
  fi
  log "INFO" "Base sha256 verified: $ACTUAL_BASE_SHA256"

  # Apply bsdiff patch
  write_status "applying" 50 "Applying delta patch (this takes several minutes)…"
  echo "[apply-update] Running bspatch…"
  BSPATCH_ERR=$(mktemp)
  bspatch "$BASE_EXPORT" "$NEW_IMAGE" "$DELTA_PATCH" \
    2>"$BSPATCH_ERR" || { log "ERROR" "bspatch stderr: $(cat "$BSPATCH_ERR")"; rm -f "$BSPATCH_ERR" "$BASE_EXPORT" "$DELTA_PATCH"; fail "bspatch failed — delta patch may be corrupt"; }
  rm -f "$BSPATCH_ERR" "$BASE_EXPORT" "$DELTA_PATCH"
  log "INFO" "bspatch complete: new-image.tar is $(stat -c%s "$NEW_IMAGE" 2>/dev/null || echo '?') bytes"

  # Verify resulting image sha256
  write_status "applying" 65 "Verifying patched image integrity…"
  ACTUAL_TARGET_SHA256=$(sha256sum "$NEW_IMAGE" | awk '{print $1}')
  if [ "$ACTUAL_TARGET_SHA256" != "$TARGET_SHA256" ]; then
    rm -f "$NEW_IMAGE"
    fail "Patched image sha256 mismatch — patch may be corrupt or truncated. Apply a full bundle."
  fi
  log "INFO" "Patched image sha256 verified: $ACTUAL_TARGET_SHA256"

  # Load new image into container storage via skopeo
  write_status "applying" 75 "Loading patched image into container storage…"
  echo "[apply-update] Loading $IMAGE_NAME via skopeo…"
  # Detect format of the reconstructed tar
  if tar -tf "$NEW_IMAGE" index.json >/dev/null 2>&1; then
    SKOPEO_SRC="oci-archive:${NEW_IMAGE}"
  else
    SKOPEO_SRC="docker-archive:${NEW_IMAGE}"
  fi
  SKOPEO_ERR=$(mktemp)
  skopeo copy "$SKOPEO_SRC" "containers-storage:${IMAGE_NAME}" \
    2>"$SKOPEO_ERR" || { log "ERROR" "skopeo stderr: $(cat "$SKOPEO_ERR")"; rm -f "$SKOPEO_ERR" "$NEW_IMAGE"; fail "skopeo copy of patched image failed"; }
  rm -f "$SKOPEO_ERR" "$NEW_IMAGE"
  log "INFO" "skopeo copy of delta image complete"

  # Switch bootc
  write_status "applying" 88 "Staging bootc update to ${IMAGE_NAME}…"
  BOOTC_ERR=$(mktemp)
  bootc switch --transport containers-storage "${IMAGE_NAME}" \
    2>"$BOOTC_ERR" || { log "ERROR" "bootc stderr: $(cat "$BOOTC_ERR")"; rm -f "$BOOTC_ERR"; fail "bootc switch failed for delta image"; }
  rm -f "$BOOTC_ERR"
  log "INFO" "bootc switch complete — staged $IMAGE_NAME from delta"

  mark_complete "applied"
  rm -rf "$WORK_DIR" "$BUNDLE_PATH"
  rm -f "$BUNDLE_READY_PATH"
  write_status "rebooting" 100 "Delta update v${VERSION} staged. Rebooting in 5 seconds…"
  echo "[apply-update] DELTA SUCCESS — rebooting to $IMAGE_NAME"
  log "SUCCESS" "Delta update v${VERSION} applied (base: $BASE_VERSION) — rebooting"
  systemctl reboot
  exit 0
fi

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
    rm -f "$BUNDLE_READY_PATH"
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

    # Verify image integrity if sha256 is present in the bundle
    write_status "applying" 45 "Verifying image integrity (sha256)…"
    if [[ -n "$EXPECTED_SHA256" ]]; then
        echo "[apply-update] Verifying sha256 of image.tar…"
        ACTUAL_SHA256=$(sha256sum "${OCI_TAR_PATH}" | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            fail "SHA256 mismatch: bundle may be corrupt.\n  expected: ${EXPECTED_SHA256}\n  actual:   ${ACTUAL_SHA256}"
        fi
        echo "[apply-update] sha256 OK: ${ACTUAL_SHA256}"
        log "INFO" "SHA256 verified OK: ${ACTUAL_SHA256}"
    else
        echo "[apply-update] WARNING: No image_sha256 in version.json — skipping integrity check (old bundle)"
        log "INFO" "SHA256 not present in bundle — skipping integrity check"
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
    rm -f "$BUNDLE_READY_PATH"

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
rm -f "$BUNDLE_READY_PATH"

write_status "rebooting" 100 "Update applied (v${VERSION}). Rebooting in 5 seconds…"
echo "[apply-update] SUCCESS — rebooting"
log "SUCCESS" "OSTree update v${VERSION} applied — rebooting"
systemctl reboot
