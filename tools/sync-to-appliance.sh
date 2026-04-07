#!/usr/bin/env bash
# sync-to-appliance.sh — copy cockpit-iot-updater files into the inferno-appliance
#                         source repository so they get baked into the OCI image.
#
# Run this on the jumphost before building a new appliance image on PRX-01.
# It copies files from this repo into the appliance source tree, which is then
# sync'd to PRX-01 and built with podman.
#
# Usage:
#   tools/sync-to-appliance.sh [--appliance-src <path>]
#
# Default appliance source: /home/legopc/copilot_projects/Inferno_Appliance/inferno-aoip-releases
#
# After running this, the appliance source will contain:
#   iot-updater/
#   ├── cockpit-page/
#   │   ├── manifest.json
#   │   ├── index.html
#   │   ├── update.js
#   │   └── updater.css
#   ├── sidecar/
#   │   └── server.py
#   ├── scripts/
#   │   └── apply-update.sh
#   └── systemd/
#       ├── iot-updater.service
#       └── iot-update.service
#
# The appliance Containerfile must reference these paths (see docs/DEPLOYMENT-V9.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_APPLIANCE="/home/legopc/copilot_projects/Inferno_Appliance/inferno-aoip-releases"
APPLIANCE_SRC="${1:-}"

# Parse --appliance-src argument
while [[ $# -gt 0 ]]; do
    case "$1" in
        --appliance-src) APPLIANCE_SRC="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--appliance-src /path/to/inferno-aoip-releases]"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

APPLIANCE_SRC="${APPLIANCE_SRC:-$DEFAULT_APPLIANCE}"

if [[ ! -d "$APPLIANCE_SRC" ]]; then
    echo "ERROR: Appliance source directory not found: $APPLIANCE_SRC"
    echo "  Clone it first or specify --appliance-src <path>"
    exit 1
fi

DEST="$APPLIANCE_SRC/iot-updater"

echo "Syncing cockpit-iot-updater files into appliance source…"
echo "  Source: $REPO_ROOT"
echo "  Dest:   $DEST"
echo ""

# Create destination structure
mkdir -p "$DEST/cockpit-page"
mkdir -p "$DEST/sidecar"
mkdir -p "$DEST/scripts"
mkdir -p "$DEST/systemd"

# Cockpit page
echo "  → cockpit-page/manifest.json"
install -m 644 "$REPO_ROOT/cockpit-page/manifest.json" "$DEST/cockpit-page/manifest.json"
echo "  → cockpit-page/index.html"
install -m 644 "$REPO_ROOT/cockpit-page/index.html"    "$DEST/cockpit-page/index.html"
echo "  → cockpit-page/update.js"
install -m 644 "$REPO_ROOT/cockpit-page/update.js"     "$DEST/cockpit-page/update.js"
echo "  → cockpit-page/updater.css"
install -m 644 "$REPO_ROOT/cockpit-page/updater.css"   "$DEST/cockpit-page/updater.css"

# Sidecar and apply script
echo "  → sidecar/server.py"
install -m 755 "$REPO_ROOT/sidecar/server.py"          "$DEST/sidecar/server.py"
echo "  → scripts/apply-update.sh"
install -m 755 "$REPO_ROOT/scripts/apply-update.sh"    "$DEST/scripts/apply-update.sh"

# Systemd units
echo "  → systemd/iot-updater.service"
install -m 644 "$REPO_ROOT/systemd/iot-updater.service" "$DEST/systemd/iot-updater.service"
echo "  → systemd/iot-update.service"
install -m 644 "$REPO_ROOT/systemd/iot-update.service"  "$DEST/systemd/iot-update.service"

echo ""
echo "✓ Sync complete."
echo ""
echo "Next steps:"
echo "  1. Verify the Containerfile in $APPLIANCE_SRC includes:"
echo "       COPY iot-updater/cockpit-page/  /usr/share/cockpit/iot-updater/"
echo "       COPY iot-updater/sidecar/server.py /var/lib/iot-updater/server.py"
echo "       COPY iot-updater/scripts/apply-update.sh /var/lib/iot-updater/apply-update.sh"
echo "       COPY iot-updater/systemd/iot-updater.service /etc/systemd/system/iot-updater.service"
echo "       COPY iot-updater/systemd/iot-update.service  /etc/systemd/system/iot-update.service"
echo "       RUN chmod +x /var/lib/iot-updater/apply-update.sh && \\"
echo "           systemctl enable iot-updater"
echo ""
echo "  2. Sync the appliance source to PRX-01:"
echo "       rsync -av $APPLIANCE_SRC/ root@10.10.1.201:/mnt/inferno-build/inferno-aoip-releases/"
echo ""
echo "  3. Build the new image on PRX-01 — see docs/DEPLOYMENT-V9.md"
