# Cockpit IoT Updater — Architecture & Technical Reference

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Browser (Cockpit session, port 9090, TLS)                     │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  cockpit-page/index.html + update.js                   │    │
│  │  • Drag-drop file picker                               │    │
│  │  • Reads version.json before committing upload         │    │
│  │  • Sends 8 MB chunks via cockpit.http()                │    │
│  │  • Polls /status every 2s during apply                 │    │
│  │  • Polls /bootc-status every 10s for deployment info   │    │
│  │  • Displays SHA-256 hash in version preview            │    │
│  │  • Rollback button shown when rollback slot exists     │    │
│  └────────────────────────────────────────────────────────┘    │
│        │  cockpit.http(8088)  ← routes through bridge WS       │
└────────│────────────────────────────────────────────────────────┘
         │
         ▼  TCP 127.0.0.1:8088  (loopback only)
┌─────────────────────────────────────────────────────────────────┐
│  sidecar/server.py  (iot-updater.service, root)                │
│                                                                 │
│  State machine:                                                 │
│    idle → uploading → verifying → staged → applying → idle     │
│    (any stage can transition to error on failure)              │
│                                                                 │
│  Upload storage: /var/tmp/iot43-update.iotupdate               │
│  History:        /var/lib/iot-updater/history.json             │
│  Apply signal:   systemctl start iot-update.service            │
│  Status file:    /var/lib/iot-updater/status.json              │
└─────────────────────────────────────────────────────────────────┘
         │  systemctl start iot-update.service
         ▼
┌─────────────────────────────────────────────────────────────────┐
│  scripts/apply-update.sh  (iot-update.service, root, oneshot)  │
│                                                                 │
│  1. Reads version.json from bundle                             │
│  2. Verifies SHA-256 hash (if present in version.json)         │
│  3. Extracts image.tar from bundle (to /var/tmp/)              │
│  4. skopeo copy oci-archive:/var/tmp/image.tar                 │
│        containers-storage:localhost/inferno-appliance:vN        │
│  5. bootc switch --transport containers-storage …              │
│  6. Writes {stage:idle} to status.json                         │
│  7. systemctl reboot                                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why cockpit.http() instead of fetch()

Cockpit 359+ enforces a strict Content Security Policy that blocks `fetch()` calls
from the Cockpit HTTPS page to `http://127.0.0.1`. The only supported way to reach
the sidecar is via `cockpit.http(port)`, which routes through the Cockpit bridge
WebSocket (already TLS). No HTTPS is needed on the sidecar itself.

---

## File locations on the device

| Path | Purpose |
|------|---------|
| `/var/lib/iot-updater/server.py` | Sidecar HTTP server |
| `/var/lib/iot-updater/apply-update.sh` | Update apply script (run as root by iot-update.service) |
| `/var/lib/iot-updater/history.json` | Persistent update history |
| `/var/lib/iot-updater/status.json` | Written by apply-update.sh to signal completion |
| `/var/tmp/iot43-update.iotupdate` | Bundle landing zone (temporary) |
| `/var/tmp/iot-update-work/` | Working directory during apply (image.tar extracted here) |
| `/etc/systemd/system/iot-updater.service` | Persistent sidecar unit |
| `/etc/systemd/system/iot-update.service` | Oneshot apply unit (started on demand) |
| `~/.local/share/cockpit/iot-updater/` | Cockpit page (user-local install, no root needed) |
| `/usr/share/cockpit/iot-updater/` | Cockpit page (system-wide install, requires writable /usr) |

---

## Bundle format (.iotupdate)

A `.iotupdate` file is a standard tar archive containing exactly two files:

```
bundle.iotupdate
├── version.json       ← metadata (read first by sidecar and UI)
└── image.tar          ← OCI image archive (skopeo-compatible)
```

### version.json schema

```json
{
  "version":      "v9",
  "description":  "Add IoT Updater baked in; sha256 integrity; rollback UI",
  "built_at":     "2025-05-14T12:00:00Z",
  "image_name":   "inferno-appliance",
  "image_sha256": "abc123..."
}
```

- `image_sha256` is the SHA-256 of `image.tar` inside the bundle.
- The sidecar streams through `image.tar` in-memory (no extraction) to verify the hash.

---

## Sidecar state machine

```
        ┌──────────────────────────────────────────────────────────┐
        │                                                          │
  POST /upload/start                                    POST /upload/cancel
        │                                                    ▲
        ▼                                                    │
     uploading ──────── 8 MB chunks via POST /upload ────────┤
        │                                                    │
        │  (all chunks received)                             │
        ▼                                                    │
     verifying ── reads version.json, verifies SHA-256 ──────┤
        │                                                    │
        │  POST /upload/apply                                │
        ▼                                                    │
      staged ─── user reviews preview ───────────────────────┤
        │                                                    │
        │  (systemctl start iot-update.service)              │
        ▼                                                    │
     applying ── apply-update.sh running ────────────────────┤
        │                                                    │
        │  (apply-update.sh writes status.json → idle)       │
        ▼                                                    │
       idle ◄──────── POST /rollback (also reboot) ──────────┘
        │
        │  (any unhandled exception)
        ▼
      error ──── POST /upload/cancel or POST /rollback ───► idle
```

---

## Sidecar API summary

See [SIDECAR-API.md](SIDECAR-API.md) for the full endpoint reference.

| Method | Endpoint | Description |
|--------|---------|-------------|
| GET | `/status` | Current upload/apply state + progress |
| GET | `/history` | All past update records |
| GET | `/bootc-status` | `bootc status` JSON — booted/staged/rollback deployments |
| GET | `/version-preview?file=<path>` | Parse version.json from a staged bundle |
| POST | `/upload/start` | Begin upload session (filename, size) |
| POST | `/upload` | Send one 8 MB chunk |
| POST | `/upload/apply` | Confirm staged bundle, start apply |
| POST | `/upload/cancel` | Abort upload, return to idle |
| POST | `/rollback` | Run `bootc rollback --apply` (stages rollback + reboots) |

---

## OCI apply path — step by step

1. **Upload** — sidecar streams chunks to `/var/tmp/iot43-update.iotupdate`
2. **Verify** — sidecar opens tar, streams `image.tar` through `hashlib.sha256()` in memory
3. **Staged** — version.json is parsed; UI shows preview with hash
4. **Apply** — `iot-update.service` starts `apply-update.sh` as root:
   - Re-verifies SHA-256 with `sha256sum`
   - Extracts `image.tar` to `/var/tmp/iot-update-work/`
   - `skopeo copy oci-archive:/var/tmp/iot-update-work/image.tar containers-storage:localhost/inferno-appliance:vN`
   - `bootc switch --transport containers-storage localhost/inferno-appliance:vN`
   - Writes `{stage: idle}` to `/var/lib/iot-updater/status.json`
   - `systemctl reboot`
5. **Rollback** — after a successful update, old image sits in the bootc rollback slot.
   `POST /rollback` → `bootc rollback --apply` → reboots into old image.

---

## bootc status polling

The UI calls `GET /bootc-status` every 10 seconds. The sidecar caches the result for 5 seconds
(to avoid hammering `bootc status` during rapid polling). Response:

```json
{
  "booted":   { "image": "localhost/inferno-appliance:v8", "digest": "sha256:…", "version": "v8", "timestamp": "…" },
  "staged":   null,
  "rollback": { "image": "localhost/inferno-appliance:v7", "digest": "sha256:…", "version": "v7", "timestamp": "…" }
}
```

The rollback UI section is hidden until `rollback` is non-null.

---

## SELinux note

Files in `/var/lib/` get SELinux context `var_lib_t`. systemd `ExecStart=` cannot directly exec
them (exits with status 203/EXEC). The apply service uses:

```ini
ExecStart=/usr/bin/bash /var/lib/iot-updater/apply-update.sh
```

Binaries that must be exec'd directly should live in `/usr/local/bin/` (`bin_t`).
