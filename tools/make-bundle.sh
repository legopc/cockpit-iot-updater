#!/usr/bin/env bash
# make-bundle.sh — generate a Fedora IoT OSTree update bundle (.iotupdate)
#
# Usage:
#   ./tools/make-bundle.sh \
#     --version 43.1.2 \
#     --description "Bug fixes and kernel update" \
#     --repo /srv/ostree-repo \
#     --from <base-commit-hash> \
#     --to   <target-commit-hash> \
#     --out  /tmp/iot43-43.1.2.iotupdate
#
# Run this on a staging/developer machine (NOT on the IoT device).
# Requires: ostree

set -euo pipefail

usage() {
    echo "Usage: $0 --version VER --description DESC --repo REPO --from COMMIT --to COMMIT --out FILE"
    echo ""
    echo "  --version      Semantic version for this bundle (e.g. 43.1.2)"
    echo "  --description  Human-readable change description"
    echo "  --repo         Path to local OSTree repository"
    echo "  --from         Base commit hash (currently deployed on devices)"
    echo "  --to           Target commit hash (the update)"
    echo "  --out          Output .iotupdate file path"
    echo ""
    echo "Example:"
    echo "  $0 --version 43.1.2 --description 'Kernel 6.12 + hardening' \\"
    echo "     --repo /srv/fedora-iot-repo --from abc123 --to def456 \\"
    echo "     --out /tmp/iot43-43.1.2.iotupdate"
    exit 1
}

VERSION="" DESCRIPTION="" REPO="" FROM="" TO="" OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)     VERSION="$2"; shift 2 ;;
        --description) DESCRIPTION="$2"; shift 2 ;;
        --repo)        REPO="$2"; shift 2 ;;
        --from)        FROM="$2"; shift 2 ;;
        --to)          TO="$2"; shift 2 ;;
        --out)         OUT="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$VERSION" || -z "$DESCRIPTION" || -z "$REPO" || -z "$FROM" || -z "$TO" || -z "$OUT" ]] && usage

# Validate repo
[[ -d "$REPO" ]] || { echo "ERROR: OSTree repo not found: $REPO"; exit 1; }
ostree --repo="$REPO" show "$FROM" > /dev/null 2>&1 \
    || { echo "ERROR: from-commit '$FROM' not found in repo"; exit 1; }
ostree --repo="$REPO" show "$TO" > /dev/null 2>&1 \
    || { echo "ERROR: to-commit '$TO' not found in repo"; exit 1; }

# Validate output path
OUT_DIR=$(dirname "$OUT")
[[ -d "$OUT_DIR" ]] || { echo "ERROR: Output directory does not exist: $OUT_DIR"; exit 1; }
[[ "$OUT" == *.iotupdate ]] || { echo "ERROR: Output file must end in .iotupdate"; exit 1; }

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

BUILD_DATE=$(date -u +"%Y-%m-%d")

echo "═══════════════════════════════════════════════════"
echo "  Fedora IoT Update Bundle Generator"
echo "  Version:     $VERSION"
echo "  Description: $DESCRIPTION"
echo "  From:        ${FROM:0:16}…"
echo "  To:          ${TO:0:16}…"
echo "  Output:      $OUT"
echo "═══════════════════════════════════════════════════"
echo ""

# ── Step 1: Write version.json ────────────────────────────────────────────────
echo "[1/3] Writing version.json…"
cat > "$TMPDIR/version.json" << EOF
{
  "version": "$VERSION",
  "build_date": "$BUILD_DATE",
  "description": "$DESCRIPTION",
  "from_commit": "$FROM",
  "to_commit": "$TO",
  "fedora_ref": "fedora/stable/aarch64/iot",
  "generator": "make-bundle.sh",
  "generator_version": "1"
}
EOF

# ── Step 2: Generate OSTree static delta ──────────────────────────────────────
echo "[2/3] Generating OSTree static delta (this may take several minutes)…"
ostree --repo="$REPO" static-delta generate \
    --min-fallback-size=0 \
    --filename="$TMPDIR/update.delta" \
    --from="$FROM" "$TO"

DELTA_SIZE=$(du -sh "$TMPDIR/update.delta" | cut -f1)
echo "      Delta size: $DELTA_SIZE"

# ── Step 3: Package into .iotupdate tar ───────────────────────────────────────
echo "[3/3] Packaging into $OUT…"
tar -cf "$OUT" -C "$TMPDIR" version.json update.delta

BUNDLE_SIZE=$(du -sh "$OUT" | cut -f1)

echo ""
echo "✓ Bundle created successfully!"
echo "  File:    $OUT"
echo "  Size:    $BUNDLE_SIZE"
echo "  Version: $VERSION"
echo ""
echo "To apply: upload via the Cockpit IoT Updater page, or run:"
echo "  scp $OUT user@device:/var/tmp/"
echo "  ssh user@device 'sudo /var/lib/iot-updater/apply-update.sh'"
