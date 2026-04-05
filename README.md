# cockpit-iot-updater

A Cockpit web UI page for delivering and applying ~2 GB OCI container image updates to
**bootc-managed** Fedora IoT 43 devices — without touching the command line.

## Features

- **Chunked upload** — streams 2 GB bundles in 8 MB chunks; no browser memory issues
- **Version preview** — reads `version.json` from the bundle before committing the upload
- **SHA-256 integrity** — bundle hash is computed at build time and verified server-side before apply
- **bootc status panel** — shows booted / staged / rollback deployment info from `bootc status`
- **One-click rollback** — rolls back to the previous deployment slot via `bootc rollback`
- **Update history** — timestamped log of all updates applied through the UI
- **Sidecar API** — lightweight Python stdlib HTTP server; no external dependencies

## How it works

```
Browser (Cockpit session, port 9090, TLS)
  └─► cockpit.http(8088)  [routes through Cockpit bridge WebSocket]
        └─► Python sidecar on 127.0.0.1:8088
              ├─ streams bundle to /var/tmp/   (no RAM buffer)
              ├─ reads version.json → shows preview in UI
              ├─ verifies SHA-256 hash
              └─ on confirm → systemctl start iot-update.service
                    └─ skopeo copy oci-archive:image.tar containers-storage:…
                    └─ bootc switch --transport containers-storage …
                    └─ reboot
```

Cockpit's built-in bridge cannot handle 2 GB files (128 KB message limit).
This project uses a lightweight Python stdlib sidecar for the actual transfer.
The sidecar binds to `127.0.0.1` only — never directly reachable from the network.

## Install on the device

```bash
git clone https://github.com/legopc/cockpit-iot-updater
cd cockpit-iot-updater
sudo ./install.sh
```

**Requirements:**
- Fedora IoT 43 managed by `bootc` (OCI image transport)
- `cockpit` installed and running (`systemctl enable --now cockpit.socket`)
- `skopeo` — for OCI archive import (`sudo rpm-ostree install skopeo`)
- `bootc` — bootc v1.14+ (included in recent Fedora IoT 43 images)
- Python 3 (included in Fedora IoT base)

**After install:**
1. Open `https://<device-ip>:9090` in a browser
2. Log in with your system credentials
3. Click **IoT Updater** in the Cockpit sidebar

## Generating update bundles (on the build host)

Bundles are created **offline on the build host** (PRX-01 or any machine with podman).
See [docs/BUILDING-UPDATES.md](docs/BUILDING-UPDATES.md) for the full guide.

Quick reference:

```bash
# Build the OCI image (on build host)
cd /mnt/inferno-build/inferno-aoip-releases
podman build -t inferno-appliance:v9 .

# Package it as a .iotupdate bundle
tools/make-oci-bundle.sh \
    --image       inferno-appliance:v9 \
    --version     v9 \
    --description "Add IoT Updater baked in; sha256 integrity; rollback UI" \
    --out         /tmp/inferno-appliance-v9.iotupdate
```

## Uploading an update

1. Open the Cockpit IoT Updater page
2. Drag-and-drop (or browse for) the `.iotupdate` file
3. Review the version preview — SHA-256 hash shown for verification
4. Click **Apply vN** and confirm
5. Wait for progress bar — `skopeo copy` takes 1–3 minutes at ~50%
6. Device reboots automatically; Cockpit reconnects to the new version

## Rollback

After a successful update, the previous deployment becomes the rollback slot.
The **Rollback** button appears automatically in the bootc status panel.

Clicking Rollback:
1. Calls `bootc rollback --apply`
2. Reboots to the previous deployment
3. Current deployment becomes the new rollback slot

> **Note:** `/etc` changes are not carried back during rollback. Rollback is a
> bootc-native operation — it switches the OS layer only.

## Security

- Sidecar binds to `127.0.0.1:8088` only — not reachable from the network
- All browser ↔ sidecar traffic flows through the Cockpit bridge WebSocket (TLS on port 9090)
- Bundle SHA-256 is verified server-side before `skopeo copy` runs
- No user-controlled paths are passed to the shell
- Sidecar runs as root (required for `systemctl start iot-update.service`)

## Version history convention

```
vMAJOR
```

Example: `v9` = ninth appliance image revision.
The version string is embedded in `version.json` inside the bundle.

## Project structure

```
cockpit-iot-updater/
├── install.sh                     ← installer for the device
├── sidecar/
│   └── server.py                  ← Python stdlib sidecar (127.0.0.1:8088)
├── scripts/
│   └── apply-update.sh            ← sha256 verify + skopeo + bootc switch + reboot
├── cockpit-page/
│   ├── manifest.json              ← Cockpit plugin registration
│   ├── index.html                 ← Upload, status, rollback UI
│   └── update.js                  ← Chunked upload, bootc status polling, rollback
├── systemd/
│   ├── iot-updater.service        ← Persistent sidecar (always running)
│   └── iot-update.service         ← Oneshot update apply (started on demand)
├── tools/
│   ├── make-oci-bundle.sh         ← Packages podman image into .iotupdate
│   └── sync-to-appliance.sh      ← Copies updater files into appliance source repo
└── docs/
    ├── ARCHITECTURE.md            ← Technical reference: state machine, endpoints, file locations
    ├── BUNDLING.md                ← Bundle format reference (→ BUILDING-UPDATES.md for guide)
    ├── BUILDING-UPDATES.md        ← Full guide: build on PRX-01, create bundle, apply, rollback
    ├── SIDECAR-API.md             ← HTTP API reference for all sidecar endpoints
    ├── DEPLOYMENT-V9.md           ← Step-by-step v9 release guide (ISO + upgrade bundle)
    └── TROUBLESHOOTING.md         ← Common errors and fixes
```

## Further reading

- [Architecture & technical reference](docs/ARCHITECTURE.md)
- [Bundle format](docs/BUNDLING.md)
- [Building & delivering updates](docs/BUILDING-UPDATES.md)
- [Sidecar API reference](docs/SIDECAR-API.md)
- [v9 Deployment guide](docs/DEPLOYMENT-V9.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
