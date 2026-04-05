#!/usr/bin/env bash
# install.sh — install cockpit-iot-updater on a bootc-managed Fedora IoT 43 device
# Run as root on the target device.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/legopc/cockpit-iot-updater/main/install.sh | sudo bash
#   -- or --
#   sudo ./install.sh

set -euo pipefail

LIB_DIR="/var/lib/iot-updater"
COCKPIT_SYSTEM="/usr/share/cockpit/iot-updater"
COCKPIT_USER="${HOME}/.local/share/cockpit/iot-updater"

echo "════════════════════════════════════════════════════"
echo "  cockpit-iot-updater installer"
echo "  Target: Fedora IoT 43 (bootc / OCI managed)"
echo "════════════════════════════════════════════════════"
echo ""

[[ $EUID -eq 0 ]] || { echo "ERROR: Run as root (sudo)"; exit 1; }

# Check required tools
for cmd in systemctl python3 tar; do
    command -v "$cmd" > /dev/null 2>&1 || { echo "ERROR: '$cmd' not found"; exit 1; }
done

# Check bootc
if ! command -v bootc > /dev/null 2>&1; then
    echo "ERROR: 'bootc' not found."
    echo "  This installer requires a bootc-managed system (Fedora IoT 43+)."
    echo "  Install bootc with: rpm-ostree install bootc && systemctl reboot"
    exit 1
fi

# Check skopeo
if ! command -v skopeo > /dev/null 2>&1; then
    echo "ERROR: 'skopeo' not found."
    echo "  Install with: rpm-ostree install skopeo && systemctl reboot"
    exit 1
fi

# Check Cockpit
if ! command -v cockpit-bridge > /dev/null 2>&1; then
    echo "WARNING: cockpit-bridge not found. Install cockpit first:"
    echo "  rpm-ostree install cockpit && systemctl reboot"
    echo "  Then re-run this installer."
    exit 1
fi

# Find script directory (works whether run from clone or via curl)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/5] Creating directories…"
mkdir -p "$LIB_DIR"

echo "[2/5] Installing sidecar server…"
install -m 755 "$SCRIPT_DIR/sidecar/server.py"         "$LIB_DIR/server.py"
install -m 755 "$SCRIPT_DIR/scripts/apply-update.sh"   "$LIB_DIR/apply-update.sh"

echo "[3/5] Installing Cockpit page…"
# On OCI-based Fedora IoT, /usr/share/cockpit may be read-only (composefs).
# Fall back to user-local path which Cockpit also scans.
if touch /usr/share/cockpit/.writetest 2>/dev/null; then
    rm -f /usr/share/cockpit/.writetest
    install -d -m 755 "$COCKPIT_SYSTEM"
    install -m 644 "$SCRIPT_DIR/cockpit-page/manifest.json" "$COCKPIT_SYSTEM/manifest.json"
    install -m 644 "$SCRIPT_DIR/cockpit-page/index.html"    "$COCKPIT_SYSTEM/index.html"
    install -m 644 "$SCRIPT_DIR/cockpit-page/update.js"     "$COCKPIT_SYSTEM/update.js"
    echo "   Installed to $COCKPIT_SYSTEM (system-wide)"
else
    mkdir -p "$COCKPIT_USER"
    install -m 644 "$SCRIPT_DIR/cockpit-page/manifest.json" "$COCKPIT_USER/manifest.json"
    install -m 644 "$SCRIPT_DIR/cockpit-page/index.html"    "$COCKPIT_USER/index.html"
    install -m 644 "$SCRIPT_DIR/cockpit-page/update.js"     "$COCKPIT_USER/update.js"
    echo "   /usr/share/cockpit is read-only (OCI image) — installed to $COCKPIT_USER"
    echo "   Page will be visible when logged into Cockpit as: $(whoami)"
fi

echo "[4/5] Installing systemd units…"
install -m 644 "$SCRIPT_DIR/systemd/iot-updater.service" /etc/systemd/system/iot-updater.service
install -m 644 "$SCRIPT_DIR/systemd/iot-update.service"  /etc/systemd/system/iot-update.service
systemctl daemon-reload

echo "[5/5] Enabling and starting iot-updater.service…"
systemctl enable --now iot-updater.service

echo ""
echo "✓ Installation complete!"
echo ""
echo "  Sidecar:      http://127.0.0.1:8088 (via iot-updater.service)"
echo "  Cockpit page: https://<device-ip>:9090  →  IoT Updater (sidebar)"
echo ""
echo "  If cockpit is not running:"
echo "    systemctl enable --now cockpit.socket"
echo ""
echo "  To verify:"
echo "    systemctl status iot-updater.service"
echo "    curl http://127.0.0.1:8088/status"
