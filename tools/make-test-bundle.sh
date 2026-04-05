#!/usr/bin/env bash
# make-test-bundle.sh — generate a tiny .iotupdate bundle for upload testing
#
# The bundle has dry_run: true so apply-update.sh will simulate the update
# without touching ostree or rebooting the device. Safe to upload and apply.
#
# Usage:
#   ./tools/make-test-bundle.sh [--version 43.0.1-test] [--out /tmp/test.iotupdate]
#
# Output:
#   A small (~100KB) .iotupdate file ready to drop into the IoT Updater UI.

set -euo pipefail

VERSION="43.0.1-test"
OUT_FILE="/tmp/test-update.iotupdate"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --out)     OUT_FILE="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FAKE_FROM=$(head -c 20 /dev/urandom | xxd -p | tr -d '\n' | head -c 40)
FAKE_TO=$(head -c 20 /dev/urandom | xxd -p | tr -d '\n' | head -c 40)

# version.json with dry_run: true
cat > "$WORK_DIR/version.json" << EOF
{
  "version": "$VERSION",
  "build_date": "$BUILD_DATE",
  "description": "Test bundle — no actual update applied, safe to upload",
  "from_commit": "$FAKE_FROM",
  "to_commit": "$FAKE_TO",
  "dry_run": true
}
EOF

# Fake 100KB delta (random data)
dd if=/dev/urandom of="$WORK_DIR/update.delta" bs=1024 count=100 2>/dev/null

# Pack into tar (version.json first so it can be peeked without reading the delta)
tar -cf "$OUT_FILE" -C "$WORK_DIR" version.json update.delta

SIZE_KB=$(du -k "$OUT_FILE" | cut -f1)
echo "Test bundle written: $OUT_FILE (${SIZE_KB}KB)"
echo "Version: $VERSION"
echo "dry_run: true — apply-update.sh will simulate without rebooting"
