#!/usr/bin/env bash
# make-oci-bundle.sh — package an inferno-appliance OCI image into a .iotupdate bundle
#
# Usage:
#   make-oci-bundle.sh --image inferno-appliance:v9 --version v9 --description "Add foo" --out bundle.iotupdate
#   make-oci-bundle.sh --archive /path/to/image.tar --version v9 --description "Add foo" --out bundle.iotupdate
#   make-oci-bundle.sh --archive /path/to/image.tar --image-name localhost/inferno-appliance:v9 ...
#
# Requirements (run on the build host — PRX-01 or any machine with podman):
#   podman  (for --image mode, to export the image)
#   tar, python3 (standard)
#
# The output .iotupdate file can be uploaded via the Cockpit IoT Updater UI.
# It contains version.json + image.tar (the full OCI image archive).

set -euo pipefail

IMAGE=""
ARCHIVE=""
IMAGE_NAME_OVERRIDE=""
VERSION=""
DESCRIPTION=""
OUT_FILE=""

usage() {
    echo "Usage: $0 --image IMAGE[:TAG] | --archive /path/to/image.tar"
    echo "          --version vN --description TEXT --out bundle.iotupdate"
    echo ""
    echo "  --image      Podman image name+tag to export (uses 'podman save')"
    echo "  --archive    Pre-exported OCI tar file (skips 'podman save')"
    echo "  --image-name Override the oci_image_name stored in version.json"
    echo "               (useful with --archive when the image name is known)"
    echo "  --version    Version string, e.g. v9 (stored in version.json)"
    echo "  --description Human-readable change description"
    echo "  --out        Output .iotupdate file path"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)       IMAGE="$2"; shift 2 ;;
        --archive)     ARCHIVE="$2"; shift 2 ;;
        --image-name)  IMAGE_NAME_OVERRIDE="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --description) DESCRIPTION="$2"; shift 2 ;;
        --out)         OUT_FILE="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

# Validate inputs
[[ -n "$VERSION" ]]     || { echo "ERROR: --version is required"; usage; }
[[ -n "$DESCRIPTION" ]] || { echo "ERROR: --description is required"; usage; }
[[ -n "$OUT_FILE" ]]    || { echo "ERROR: --out is required"; usage; }
[[ -n "$IMAGE" || -n "$ARCHIVE" ]] || { echo "ERROR: --image or --archive is required"; usage; }
[[ -z "$IMAGE" || -z "$ARCHIVE" ]] || { echo "ERROR: Use --image OR --archive, not both"; usage; }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

IMAGE_TAR="${WORK_DIR}/image.tar"
# Determine the image name stored in version.json:
#   1. --image-name override (explicit, highest priority)
#   2. --image value (when exporting directly from podman)
#   3. "inferno-appliance:unknown" (fallback for --archive without --image-name)
if [[ -n "$IMAGE_NAME_OVERRIDE" ]]; then
    IMAGE_NAME="$IMAGE_NAME_OVERRIDE"
elif [[ -n "$IMAGE" ]]; then
    IMAGE_NAME="$IMAGE"
else
    IMAGE_NAME="inferno-appliance:unknown"
fi

# ── Export image if --image was given ─────────────────────────────────────────
if [[ -n "$IMAGE" ]]; then
    echo "Exporting podman image: ${IMAGE}"
    echo "  (This may take a few minutes for a ~2GB image…)"
    podman save --format oci-archive "${IMAGE}" -o "${IMAGE_TAR}" || {
        echo "ERROR: podman save failed. Is the image '${IMAGE}' available locally?"
        echo "  Try: podman images | grep inferno-appliance"
        exit 1
    }
    echo "  Image exported: $(du -sh "${IMAGE_TAR}" | cut -f1)"
elif [[ -n "$ARCHIVE" ]]; then
    [[ -f "$ARCHIVE" ]] || { echo "ERROR: Archive not found: $ARCHIVE"; exit 1; }
    echo "Using existing archive: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"
    cp "$ARCHIVE" "$IMAGE_TAR"
fi

# ── Compute SHA256 of image.tar ───────────────────────────────────────────────
echo "Computing SHA256 of image archive…"
IMAGE_SHA256=$(sha256sum "${IMAGE_TAR}" | awk '{print $1}')
echo "  sha256: ${IMAGE_SHA256}"

# ── Write version.json ────────────────────────────────────────────────────────
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 - <<PYEOF
import json
data = {
    "version": "${VERSION}",
    "build_date": "${BUILD_DATE}",
    "description": "${DESCRIPTION}",
    "oci_image_name": "${IMAGE_NAME}",
    "oci_image_file": "image.tar",
    "image_sha256": "${IMAGE_SHA256}"
}
with open("${WORK_DIR}/version.json", "w") as f:
    json.dump(data, f, indent=2)
print("version.json written:")
print(json.dumps(data, indent=2))
PYEOF

# ── Package into .iotupdate ───────────────────────────────────────────────────
echo ""
echo "Packaging bundle → ${OUT_FILE}"
ABS_OUT=$(realpath -m "$OUT_FILE")
pushd "$WORK_DIR" > /dev/null
tar -cf "$ABS_OUT" version.json image.tar
popd > /dev/null

BUNDLE_SIZE=$(du -sh "$ABS_OUT" | cut -f1)
echo ""
echo "✓ Bundle created: ${ABS_OUT} (${BUNDLE_SIZE})"
echo ""
echo "Upload via Cockpit IoT Updater:"
echo "  https://<device-ip>:9090  →  IoT Updater  →  drag the .iotupdate file"
