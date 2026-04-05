# cockpit-iot-updater

A Cockpit web UI page for delivering and applying ~2 GB OSTree update bundles to
Fedora IoT 43 devices — without touching the command line.

## How it works

```
Browser (Cockpit page, port 9090)
  → chunked HTTP upload (8 MB chunks via fetch)
    → Python sidecar on 127.0.0.1:8088
       → streams bundle to /var/tmp/ (no RAM buffer)
       → extracts version.json → shows preview in UI
       → on confirm → systemctl start iot-update.service
          → ostree static-delta apply-offline
          → rpm-ostree deploy <commit>
          → reboot
```

Cockpit's built-in bridge **cannot** handle 2 GB files (128 KB limit).
This project uses a lightweight Python stdlib sidecar for the actual transfer.

---

## Install on the device

```bash
git clone https://github.com/legopc/cockpit-iot-updater
cd cockpit-iot-updater
sudo ./install.sh
```

Or one-liner:
```bash
curl -fsSL https://raw.githubusercontent.com/legopc/cockpit-iot-updater/main/install.sh | sudo bash
```

**Requirements:**
- Fedora IoT 43 (rpm-ostree managed)
- `cockpit` installed: `rpm-ostree install cockpit && systemctl reboot`
- Python 3 (included in Fedora IoT base)

**After install:**
1. Open `https://<device-ip>:9090` in a browser
2. Log in with your system credentials
3. Click **IoT Updater** in the sidebar

---

## Generating update bundles (on a staging machine)

Bundles are created **offline on a developer machine** — not on the IoT device.

### Prerequisites

```bash
# Fedora/RHEL staging machine with internet access
sudo dnf install ostree
```

### Step 1 — Build or pull the updated OSTree commit

If you're composing Fedora IoT images yourself:
```bash
# After composing, your repo is at e.g. /srv/fedora-iot-repo
# Find the new commit:
ostree --repo=/srv/fedora-iot-repo log fedora/stable/aarch64/iot
```

If using an upstream Fedora IoT repo:
```bash
ostree --repo=/srv/local-mirror pull \
    https://ostree.fedoraproject.org/iot \
    fedora/stable/aarch64/iot
```

### Step 2 — Find the base and target commits

```bash
# Currently deployed commit on the device (run on the device):
rpm-ostree status --json | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['deployments'][0]['checksum'])"

# Target commit (on staging machine):
ostree --repo=/srv/fedora-iot-repo rev-parse fedora/stable/aarch64/iot
```

### Step 3 — Generate the bundle

```bash
./tools/make-bundle.sh \
    --version     43.1.2 \
    --description "Kernel 6.12.15 + security updates" \
    --repo        /srv/fedora-iot-repo \
    --from        <current-device-commit> \
    --to          <target-commit> \
    --out         /tmp/iot43-43.1.2.iotupdate
```

Output: a single `.iotupdate` file (~2 GB) containing:
- `version.json` — version metadata
- `update.delta` — OSTree static delta

### Step 4 — Upload via Cockpit

1. Open the Cockpit IoT Updater page
2. Drag and drop (or browse for) the `.iotupdate` file
3. Review the version preview — the page reads `version.json` before committing the full upload
4. Click **Apply vX.X.X**
5. Confirm the reboot dialog
6. Device applies the update and reboots automatically

---

## Version numbering convention

```
FEDORA_MAJOR.MINOR.PATCH
```

| Part          | Meaning |
|---------------|---------|
| FEDORA_MAJOR  | Fedora IoT release (43, 44, …) |
| MINOR         | Significant feature or config change |
| PATCH         | Security/bugfix-only update |

Example: `43.1.2` = Fedora IoT 43, minor release 1, bugfix 2.

The version is embedded in `version.json` inside the bundle — the bundle is the
single source of truth.

---

## Version history

The Cockpit page includes a **Version History** tab showing all updates applied
via this tool: version, timestamp, OSTree commit hashes, and status (applied / error).

History is stored at `/var/lib/iot-updater/history.json` on the device
(writable `/var` partition, persists across updates).

---

## Rollback

If an update causes problems, rpm-ostree rollback is supported natively:

```bash
rpm-ostree rollback
systemctl reboot
```

This boots the previous OSTree deployment (always kept by rpm-ostree).

---

## Security notes

- The sidecar binds to `127.0.0.1:8088` only — not reachable from the network
- Cockpit authentication (port 9090) is the access gate
- Bundle path is hardcoded (`/var/tmp/iot43-update.iotupdate`) — no user-controlled paths are passed to the shell
- The sidecar runs as root (required for `systemctl start iot-update.service` and `/var/tmp` write)

---

## Caveats

- **Fedora IoT `/usr` is read-only** — the install script places files under `/var/lib/` and `/usr/share/cockpit/` via a writable overlay (Fedora IoT supports writes to `/usr` via `rpm-ostree install` or direct write to the composefs overlay — verify on your specific build)
- **Space**: ensure `/var/tmp` has at least 2× the bundle size free before uploading
- **Reboot disconnect**: when the device reboots, the Cockpit session disconnects — this is expected
- **Single update at a time**: concurrent uploads are rejected with HTTP 409
- **Bundle compatibility**: the `from_commit` in the bundle must match the commit currently deployed on the device, or ostree will reject the delta

---

## Project structure

```
cockpit-iot-updater/
├── install.sh                    ← installer for the device
├── sidecar/
│   └── server.py                 ← Python stdlib HTTP receiver (127.0.0.1:8088)
├── scripts/
│   └── apply-update.sh           ← ostree apply + rpm-ostree deploy + reboot
├── cockpit-page/
│   ├── manifest.json             ← Cockpit plugin registration
│   ├── index.html                ← Upload + History tabs
│   └── update.js                 ← Chunked upload logic, version preview, status polling
├── systemd/
│   ├── iot-updater.service       ← Persistent sidecar (always running)
│   └── iot-update.service        ← Oneshot update apply (started on demand)
├── tools/
│   └── make-bundle.sh            ← Run on staging machine to generate .iotupdate bundles
└── docs/
    └── BUNDLING.md               ← Detailed bundle creation guide
```
