#!/usr/bin/env bash
# make-delta-bundle.sh — build-host tool to create a delta .iotupdate bundle
#
# ── Intended design (NOT YET IMPLEMENTED) ────────────────────────────────────
#
# A delta bundle is a .iotupdate tar containing:
#
#   version.json   — bundle metadata with delta-specific fields:
#                      "bundle_type":    "delta"
#                      "version":        <target version string>
#                      "base_version":   <version string of the running image>
#                      "base_sha256":    <sha256 of the base image.tar the patch applies to>
#                      "target_sha256":  <sha256 of the resulting image after patch>
#                      "description":    <human-readable description>
#                      "changelog":      <optional change notes>
#
#   delta.patch    — binary diff in bsdiff format between base image.tar and
#                    target image.tar
#
# Apply flow (scripts/apply-update.sh, once implemented):
#   1. Detect bundle_type == "delta" in version.json
#   2. Verify the currently booted image matches base_sha256
#      (fail fast if the appliance is not on the expected base version)
#   3. Apply delta.patch via bspatch:
#        bspatch <base-image.tar> <new-image.tar> delta.patch
#   4. Verify the resulting image.tar sha256 matches target_sha256
#   5. Proceed exactly as a full OCI bundle (skopeo copy + bootc switch)
#
# Build-host requirements (not yet wired up):
#   bsdiff     — to generate delta.patch from two OCI image tars
#   podman     — to export base and target OCI images
#   python3    — to write version.json
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BASE_IMAGE=""
TARGET_IMAGE=""
OUT_FILE=""
CHANGELOG=""

usage() {
    echo "Usage: $0 --base <image[:tag]> --target <image[:tag]> --out <file.iotupdate> [--changelog <text>]"
    echo ""
    echo "  --base       Base image (currently running on appliance)"
    echo "  --target     Target image (version to upgrade to)"
    echo "  --out        Output .iotupdate bundle file"
    echo "  --changelog  Optional change notes"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)      BASE_IMAGE="$2";  shift 2 ;;
        --target)    TARGET_IMAGE="$2"; shift 2 ;;
        --out)       OUT_FILE="$2";    shift 2 ;;
        --changelog) CHANGELOG="$2";   shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -n "$BASE_IMAGE" ]]   || { echo "ERROR: --base is required";   usage; }
[[ -n "$TARGET_IMAGE" ]] || { echo "ERROR: --target is required"; usage; }
[[ -n "$OUT_FILE" ]]     || { echo "ERROR: --out is required";    usage; }

echo "ERROR: Delta bundles are not yet implemented." >&2
echo "       Use make-oci-bundle.sh to create a full bundle instead." >&2
exit 1
