#!/usr/bin/env bash
# make-delta-bundle.sh — create a delta .iotupdate bundle (bsdiff patch between two OCI image tars)
#
# The output .iotupdate file contains:
#   version.json  — bundle metadata (bundle_type: "delta")
#   delta.patch   — bsdiff binary patch from base image.tar → target image.tar
#
# Apply flow (apply-update.sh):
#   1. Detect bundle_type == "delta" in version.json
#   2. Verify booted image sha256 matches base_sha256
#   3. bspatch <base.tar> <new.tar> delta.patch
#   4. Verify new.tar sha256 matches target_sha256
#   5. Proceed as full OCI bundle (skopeo copy + bootc switch)

set -euo pipefail

BASE_IMAGE=""
BASE_ARCHIVE=""
TARGET_IMAGE=""
TARGET_ARCHIVE=""
IMAGE_NAME_OVERRIDE=""
BASE_VERSION=""
VERSION=""
DESCRIPTION=""
CHANGELOG=""
OUT_FILE=""
SIGN_KEY=""
MANIFEST_URL=""
VALID_DAYS=""

usage() {
    echo "Usage: $0 --base-image IMAGE[:TAG] | --base-archive /path/to/base.tar"
    echo "          --target-image IMAGE[:TAG] | --target-archive /path/to/target.tar"
    echo "          --base-version vN --version vM --description TEXT --out bundle.iotupdate"
    echo ""
    echo "  --base-image      Base podman image to export (uses 'podman save')"
    echo "  --base-archive    Pre-exported base OCI tar (skips podman save)"
    echo "  --target-image    Target podman image to export"
    echo "  --target-archive  Pre-exported target OCI tar"
    echo "  --image-name      Override oci_image_name in version.json"
    echo "  --base-version    Version string of the base image, e.g. v8"
    echo "  --version         Version string of the target image, e.g. v9"
    echo "  --description     Human-readable change description"
    echo "  --changelog       Optional change notes (shown in UI)"
    echo "  --out             Output .iotupdate file path"
    echo "  --sign-key        Path to Ed25519 private key for signing version.json"
    echo "  --manifest-url    URL of the JSON manifest for auto-update checks"
    echo "  --valid-days N    Bundle expiry: N days from today"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-image)      BASE_IMAGE="$2";          shift 2 ;;
        --base-archive)    BASE_ARCHIVE="$2";        shift 2 ;;
        --target-image)    TARGET_IMAGE="$2";        shift 2 ;;
        --target-archive)  TARGET_ARCHIVE="$2";      shift 2 ;;
        --image-name)      IMAGE_NAME_OVERRIDE="$2"; shift 2 ;;
        --base-version)    BASE_VERSION="$2";        shift 2 ;;
        --version)         VERSION="$2";             shift 2 ;;
        --description)     DESCRIPTION="$2";         shift 2 ;;
        --changelog)       CHANGELOG="$2";           shift 2 ;;
        --out)             OUT_FILE="$2";            shift 2 ;;
        --sign-key)        SIGN_KEY="$2";            shift 2 ;;
        --manifest-url)    MANIFEST_URL="$2";        shift 2 ;;
        --valid-days)      VALID_DAYS="$2";          shift 2 ;;
        -h|--help)         usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

# ── Validate required arguments ───────────────────────────────────────────────
[[ -n "$BASE_VERSION" ]]  || { echo "ERROR: --base-version is required"; usage; }
[[ -n "$VERSION" ]]       || { echo "ERROR: --version is required"; usage; }
[[ -n "$DESCRIPTION" ]]   || { echo "ERROR: --description is required"; usage; }
[[ -n "$OUT_FILE" ]]      || { echo "ERROR: --out is required"; usage; }
[[ -n "$BASE_IMAGE" || -n "$BASE_ARCHIVE" ]]     || { echo "ERROR: --base-image or --base-archive is required"; usage; }
[[ -z "$BASE_IMAGE" || -z "$BASE_ARCHIVE" ]]     || { echo "ERROR: Use --base-image OR --base-archive, not both"; usage; }
[[ -n "$TARGET_IMAGE" || -n "$TARGET_ARCHIVE" ]] || { echo "ERROR: --target-image or --target-archive is required"; usage; }
[[ -z "$TARGET_IMAGE" || -z "$TARGET_ARCHIVE" ]] || { echo "ERROR: Use --target-image OR --target-archive, not both"; usage; }

# ── Preflight checks ──────────────────────────────────────────────────────────
command -v bsdiff &>/dev/null || {
    echo "ERROR: bsdiff not installed."
    echo "  Install with: apt install bsdiff   (Debian/Ubuntu)"
    echo "                dnf install bsdiff   (Fedora/RHEL)"
    exit 1
}

# Check available disk space (require ≥ 10 GB)
AVAIL_KB=$(df --output=avail "$(pwd)" 2>/dev/null | tail -1 || df "$(pwd)" | awk 'NR==2{print $4}')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
if (( AVAIL_GB < 10 )); then
    echo "ERROR: Insufficient disk space. Need at least 10 GB, found ${AVAIL_GB} GB available."
    echo "  The delta process needs base.tar + target.tar + delta.patch simultaneously."
    exit 1
fi
echo "Disk available: ${AVAIL_GB} GB ✓"

# Warn if less than 6 GB RAM free
MEM_FREE_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_FREE_GB=$(( MEM_FREE_KB / 1024 / 1024 ))
if (( MEM_FREE_GB < 6 )); then
    echo "WARNING: Low free RAM (${MEM_FREE_GB} GB). bsdiff may be slow with large images."
    echo "  Recommended: ≥6 GB free RAM for 2 GB OCI image archives."
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

BASE_TAR="${WORK_DIR}/base.tar"
TARGET_TAR="${WORK_DIR}/target.tar"

# ── Helper: detect archive format ─────────────────────────────────────────────
detect_format() {
    local tar_path="$1"
    if tar -tf "$tar_path" index.json &>/dev/null 2>&1; then
        echo "oci"
    elif tar -tf "$tar_path" manifest.json &>/dev/null 2>&1; then
        echo "docker"
    else
        echo "unknown"
    fi
}

# ── Get target image tar ──────────────────────────────────────────────────────
# Target is processed first so we know ARCHIVE_FORMAT before normalising the base.
if [[ -n "$TARGET_IMAGE" ]]; then
    echo "Exporting target image from containers-storage: ${TARGET_IMAGE}"
    echo "  (This may take a few minutes for a large image…)"
    skopeo copy "containers-storage:${TARGET_IMAGE}" "oci-archive:${TARGET_TAR}" || {
        # Fallback: try podman save
        podman save --format oci-archive "${TARGET_IMAGE}" -o "${TARGET_TAR}" || {
            echo "ERROR: Failed to export target image '${TARGET_IMAGE}'"
            exit 1
        }
    }
    echo "  Target exported: $(du -sh "${TARGET_TAR}" | cut -f1)"
else
    [[ -f "$TARGET_ARCHIVE" ]] || { echo "ERROR: Target archive not found: $TARGET_ARCHIVE"; exit 1; }
    echo "Using target archive: $TARGET_ARCHIVE ($(du -sh "$TARGET_ARCHIVE" | cut -f1))"
    cp "$TARGET_ARCHIVE" "$TARGET_TAR"
fi

echo "Validating target archive…"
tar -tf "${TARGET_TAR}" > /dev/null 2>&1 || { echo "ERROR: Target archive is not a valid tar"; exit 1; }
ARCHIVE_FORMAT=$(detect_format "$TARGET_TAR")
echo "  Target format: ${ARCHIVE_FORMAT}"

# ── Get base image tar (must be normalized through containers-storage) ─────────
# CRITICAL: apply-update.sh exports the booted image via:
#   skopeo copy containers-storage:IMAGE <format>-archive:base-export.tar
# The base_sha256 we store MUST match the sha256 of that export.
# We therefore always route --base-archive through containers-storage so both
# the build host and the appliance produce identical byte streams.
BASE_TEMP_TAG="localhost/delta-build-base-$(date +%s):temp"
BASE_TEMP_LOADED=0

if [[ -n "$BASE_IMAGE" ]]; then
    echo "Using base image from containers-storage: ${BASE_IMAGE}"
    BASE_CS_IMAGE="$BASE_IMAGE"
else
    [[ -f "$BASE_ARCHIVE" ]] || { echo "ERROR: Base archive not found: $BASE_ARCHIVE"; exit 1; }
    echo "Loading base archive into containers-storage for normalisation: $BASE_ARCHIVE"
    echo "  (This ensures base_sha256 matches what apply-update.sh will compute on the appliance)"
    RAW_FORMAT=$(detect_format "$BASE_ARCHIVE")
    if [[ "$RAW_FORMAT" == "oci" ]]; then
        LOAD_SRC="oci-archive:${BASE_ARCHIVE}"
    else
        LOAD_SRC="docker-archive:${BASE_ARCHIVE}"
    fi
    skopeo copy "$LOAD_SRC" "containers-storage:${BASE_TEMP_TAG}" || {
        echo "ERROR: Failed to load base archive into containers-storage"
        exit 1
    }
    BASE_CS_IMAGE="$BASE_TEMP_TAG"
    BASE_TEMP_LOADED=1
fi

echo "Exporting base image from containers-storage (same method as apply-update.sh)…"
echo "  (This may take a few minutes for a large image…)"
if [[ "$ARCHIVE_FORMAT" == "docker" ]]; then
    skopeo copy "containers-storage:${BASE_CS_IMAGE}" "docker-archive:${BASE_TAR}" || {
        echo "ERROR: Failed to export base image from containers-storage"; exit 1
    }
else
    skopeo copy "containers-storage:${BASE_CS_IMAGE}" "oci-archive:${BASE_TAR}" || {
        echo "ERROR: Failed to export base image from containers-storage"; exit 1
    }
fi
echo "  Base exported: $(du -sh "${BASE_TAR}" | cut -f1)"

# Cleanup temp containers-storage entry
if [[ "$BASE_TEMP_LOADED" == "1" ]]; then
    podman rmi "$BASE_TEMP_TAG" 2>/dev/null || true
fi

echo "Validating base archive…"
tar -tf "${BASE_TAR}" > /dev/null 2>&1 || { echo "ERROR: Base archive is not a valid tar"; exit 1; }
echo "  Base format: $(detect_format "$BASE_TAR")"

# Determine oci_image_name
if [[ -n "$IMAGE_NAME_OVERRIDE" ]]; then
    IMAGE_NAME="$IMAGE_NAME_OVERRIDE"
elif [[ -n "$TARGET_IMAGE" ]]; then
    IMAGE_NAME="$TARGET_IMAGE"
else
    IMAGE_NAME="inferno-appliance:unknown"
fi

# ── Compute SHA256 of both tars ───────────────────────────────────────────────
echo "Computing SHA256 of base archive…"
BASE_SHA256=$(sha256sum "${BASE_TAR}" | awk '{print $1}')
echo "  base sha256: ${BASE_SHA256}"

echo "Computing SHA256 of target archive…"
TARGET_SHA256=$(sha256sum "${TARGET_TAR}" | awk '{print $1}')
echo "  target sha256: ${TARGET_SHA256}"

# ── Generate delta patch ──────────────────────────────────────────────────────
echo ""
echo "Generating delta patch (this may take several minutes for large images)…"
bsdiff "${BASE_TAR}" "${TARGET_TAR}" "${WORK_DIR}/delta.patch"

PATCH_SIZE=$(du -sh "${WORK_DIR}/delta.patch" | cut -f1)
FULL_SIZE=$(du -sh "${TARGET_TAR}" | cut -f1)
echo "  Delta patch: ${PATCH_SIZE} (vs full: ${FULL_SIZE})"

# Warn if patch is > 80% the size of the target tar
PATCH_BYTES=$(du -sb "${WORK_DIR}/delta.patch" | cut -f1)
TARGET_BYTES=$(du -sb "${TARGET_TAR}" | cut -f1)
PATCH_PCT=$(( PATCH_BYTES * 100 / TARGET_BYTES ))
if (( PATCH_PCT > 80 )); then
    echo "  WARNING: Delta patch is ${PATCH_PCT}% the size of the full target archive."
    echo "           Consider using make-oci-bundle.sh for a full bundle instead."
fi

# ── Write version.json ────────────────────────────────────────────────────────
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

VALID_UNTIL=""
if [[ -n "$VALID_DAYS" ]]; then
    if date -d "+${VALID_DAYS} days" +%Y-%m-%d &>/dev/null 2>&1; then
        VALID_UNTIL=$(date -d "+${VALID_DAYS} days" +%Y-%m-%d)
    else
        VALID_UNTIL=$(date -v+${VALID_DAYS}d +%Y-%m-%d)
    fi
    echo "  Bundle expires: ${VALID_UNTIL} (${VALID_DAYS} days from today)"
fi

CHANGELOG_VAL="${CHANGELOG}" \
MANIFEST_URL_VAL="${MANIFEST_URL}" \
VALID_UNTIL_VAL="${VALID_UNTIL}" \
python3 - <<PYEOF
import json, os
data = {
    "bundle_type":    "delta",
    "version":        "${VERSION}",
    "base_version":   "${BASE_VERSION}",
    "base_sha256":    "${BASE_SHA256}",
    "target_sha256":  "${TARGET_SHA256}",
    "description":    "${DESCRIPTION}",
    "build_date":     "${BUILD_DATE}",
    "oci_image_name": "${IMAGE_NAME}",
    "archive_format": "${ARCHIVE_FORMAT}"
}
changelog = os.environ.get("CHANGELOG_VAL", "")
if changelog:
    data["changelog"] = changelog
manifest_url = os.environ.get("MANIFEST_URL_VAL", "")
if manifest_url:
    data["manifest_url"] = manifest_url
valid_until = os.environ.get("VALID_UNTIL_VAL", "")
if valid_until:
    data["valid_until"] = valid_until
with open("${WORK_DIR}/version.json", "w") as f:
    json.dump(data, f, indent=2)
print("version.json written:")
print(json.dumps(data, indent=2))
PYEOF

# ── Ed25519 signing ───────────────────────────────────────────────────────────
if [[ -n "$SIGN_KEY" ]]; then
    [[ -f "$SIGN_KEY" ]] || { echo "ERROR: --sign-key file not found: $SIGN_KEY"; exit 1; }
    echo "Signing version.json with Ed25519 key: ${SIGN_KEY}"
    openssl dgst -sha256 -sign "$SIGN_KEY" -out "${WORK_DIR}/bundle.sig" "${WORK_DIR}/version.json" \
        || { echo "ERROR: openssl signing failed"; exit 1; }
    SIG=$(base64 -w0 "${WORK_DIR}/bundle.sig")
    python3 - <<SIGEOF
import json
path = "${WORK_DIR}/version.json"
d = json.load(open(path))
d["signature"] = "${SIG}"
d["signed_fields"] = ["version.json"]
json.dump(d, open(path, "w"), indent=2)
SIGEOF
    rm -f "${WORK_DIR}/bundle.sig"
    echo "  Signature embedded in version.json"
fi

# ── Package into .iotupdate ───────────────────────────────────────────────────
echo ""
echo "Packaging bundle → ${OUT_FILE}"
ABS_OUT=$(realpath -m "$OUT_FILE")
cd "$WORK_DIR"
tar -cf "$ABS_OUT" version.json delta.patch

BUNDLE_SIZE=$(du -sh "$ABS_OUT" | cut -f1)
SAVINGS=$(( 100 - PATCH_BYTES * 100 / TARGET_BYTES ))

echo ""
echo "✓ Delta bundle created: ${ABS_OUT} (${BUNDLE_SIZE})"
echo "  Base:   ${BASE_VERSION} (${BASE_SHA256:0:16}…)"
echo "  Target: ${VERSION} (${TARGET_SHA256:0:16}…)"
echo "  Savings vs full: ~${SAVINGS}%"
