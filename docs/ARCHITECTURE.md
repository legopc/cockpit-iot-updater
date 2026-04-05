# Cockpit IoT Updater — Architecture & Technical Reference

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Browser (Cockpit session, port 9090)                          │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  cockpit-page/index.html + update.js                   │    │
│  │  • Drag-drop file picker                               │    │
│  │  • Reads bundle version.json before committing upload  │    │
│  │  • Sends 8 MB chunks via fetch() to sidecar            │    │
│  │  • Polls /status every 2 s for live progress           │    │
│  │  • History tab reads /history from sidecar             │    │
│  └─────────────────────┬──────────────────────────────────┘    │
└────────────────────────│────────────────────────────────────────┘
                         │ HTTP (chunked POST, GET)
                         ▼ 127.0.0.1:8088
┌─────────────────────────────────────────────────────────────────┐
│  sidecar/server.py  (iot-updater.service, always running)      │
│  • POST /upload/start  — reset state, prepare for new upload   │
│  • POST /upload        — receive chunk, append to bundle file  │
│  • GET  /status        — return current stage + progress JSON  │
│  • GET  /history       — return history.json contents          │
│  • POST /upload/apply  — trigger iot-update.service            │
│  • POST /upload/cancel — delete partial bundle, reset state    │
│                                                                  │
│  On last chunk: extracts version.json from tar bundle           │
│  On apply:      systemctl start iot-update.service              │
└─────────────────────┬───────────────────────────────────────────┘
                      │ systemctl start
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│  iot-update.service  (oneshot, root)                           │
│  → scripts/apply-update.sh                                     │
│     1. Validate bundle exists + size > 1 MB                    │
│     2. tar extract: version.json + update.delta → /var/tmp/    │
│     3. ostree static-delta apply-offline update.delta           │
│     4. rpm-ostree deploy :<to_commit>                          │
│     5. Update /var/lib/iot-updater/history.json status         │
│     6. rm bundle + delta + version.json                        │
│     7. sleep 5 && systemctl reboot                             │
│                                                                  │
│  Status written to /run/iot-update-status.json at each step    │
│  (sidecar reads and re-exposes this via GET /status)           │
└─────────────────────────────────────────────────────────────────┘
```

---

## File locations on Fedora IoT device

| Path | Purpose | Persistent? |
|------|---------|-------------|
| `/var/lib/iot-updater/server.py` | Sidecar server | ✅ (survives updates) |
| `/var/lib/iot-updater/apply-update.sh` | Update script | ✅ |
| `/var/lib/iot-updater/history.json` | Applied update log | ✅ |
| `/usr/share/cockpit/iot-updater/` | Cockpit page files | ⚠️ See note |
| `/etc/systemd/system/iot-updater.service` | Persistent sidecar unit | ⚠️ See note |
| `/etc/systemd/system/iot-update.service` | Oneshot apply unit | ⚠️ See note |
| `/var/tmp/iot43-update.iotupdate` | Upload staging (temp) | ❌ Deleted after apply |
| `/var/tmp/iot43-update.delta` | Extracted delta (temp) | ❌ Deleted after apply |
| `/run/iot-update-status.json` | Live progress (tmpfs) | ❌ Lost on reboot |

> **Note on rpm-ostree + `/usr` and `/etc`:**
> Fedora IoT's `/usr` is managed by OSTree. Writing to `/usr/share/cockpit/` directly is possible
> on a running system but may be **overwritten on the next OSTree update**. For permanent
> installation, the correct approach is to layer the package:
> ```bash
> rpm-ostree install cockpit-iot-updater   # once packaged as RPM
> ```
> Until an RPM exists, the install.sh approach works for development/testing.
> `/var/lib/` and `/var/tmp/` are always writable and survive updates.
> `/etc/systemd/system/` is writable and persists (it's in the OSTree "3-way merge" layer).

---

## Bundle format: `.iotupdate`

A `.iotupdate` file is a plain **uncompressed tar archive** containing exactly two files:

```
iot43-43.1.2.iotupdate (tar)
├── version.json      ← always first in the archive (small, read immediately)
└── update.delta      ← OSTree static delta (the bulk of the size, ~2 GB)
```

### `version.json` schema

```json
{
  "version":          "43.1.2",
  "build_date":       "2026-04-05",
  "description":      "Kernel 6.12.15 + security updates",
  "from_commit":      "<full 64-char OSTree commit hash>",
  "to_commit":        "<full 64-char OSTree commit hash>",
  "fedora_ref":       "fedora/stable/aarch64/iot",
  "generator":        "make-bundle.sh",
  "generator_version":"1"
}
```

`version.json` is placed **first in the tar** so `tarfile.getmember()` can extract it without
reading the full 2 GB delta. This is how the UI shows the version preview before the upload
is committed.

### Why uncompressed tar?

- The OSTree delta is already compressed internally
- Adding gzip on top gains negligible space and adds minutes to bundle creation
- Uncompressed tar allows streaming extraction without buffering the whole file

---

## Upload protocol: chunked HTTP

The browser splits the file client-side and sends each chunk as a separate HTTP POST:

```
POST /upload/start                        ← reset state machine
  → 200 {ok: true}

POST /upload  (chunk 0)
  Headers: X-Chunk-Index: 0
           X-Total-Chunks: 256
           Content-Length: 8388608        ← 8 MB
  Body: <binary chunk>
  → 200 {chunk: 0, progress: 0}

POST /upload  (chunk 1..N-1)
  ...
  → 200 {chunk: N-1, progress: 99}

POST /upload  (chunk N — last)
  → sidecar extracts version.json from completed bundle
  → 200 {chunk: N, progress: 100}
    state transitions to: idle (bundle ready) or error

GET /status                               ← poll every 2 s
  → {stage, progress_pct, message, version_info}

POST /upload/apply                        ← user confirms
  → systemctl start iot-update.service

GET /status                               ← continues to poll through apply + reboot
```

### State machine

```
idle ──[start upload]──► uploading ──[last chunk received]──► extracting
  ▲                                                               │
  │                                          ┌────────────────────┘
  │                          [version.json OK]│   [version.json missing/invalid]
  │                                           ▼                   ▼
  └──────────────────────[apply confirmed]── idle               error
                                              │                   │
                                              ▼                   └──[start]──► idle
                                           queued
                                              │
                                              ▼
                                          applying ──► rebooting
```

---

## Sidecar HTTP endpoints reference

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/upload/start` | — | Begin new upload session (resets state) |
| `POST` | `/upload` | — | Receive one chunk. Headers: `X-Chunk-Index`, `X-Total-Chunks` |
| `POST` | `/upload/apply` | — | Trigger `iot-update.service` after bundle is ready |
| `POST` | `/upload/cancel` | — | Delete bundle, reset to idle |
| `GET`  | `/status` | — | Current state: `{stage, progress_pct, message, version_info, error}` |
| `GET`  | `/history` | — | All applied updates: list of history entries |
| `GET`  | `/version-preview` | — | `version_info` for the current ready bundle |

> Authentication is provided by Cockpit's login page (port 9090). The sidecar binds to
> `127.0.0.1` only, so it is not directly reachable from the network — all traffic routes
> through the browser session authenticated by Cockpit.

---

## Version numbering

```
FEDORA_MAJOR . MINOR . PATCH
     43      .   1   .   2
```

| Part | Increments when |
|------|----------------|
| `FEDORA_MAJOR` | Moving to a new Fedora release (43 → 44) |
| `MINOR` | Feature additions, config changes, kernel upgrades |
| `PATCH` | Security patches, bugfixes only |

The page performs a version comparison to detect downgrades:
```js
function versionCompare(a, b) {
    const pa = a.split(".").map(Number), pb = b.split(".").map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const diff = (pa[i] || 0) - (pb[i] || 0);
        if (diff !== 0) return diff;
    }
    return 0;
}
```
A downgrade shows a warning and requires the user to check a confirmation box.

---

## `history.json` format

```json
[
  {
    "version": "43.1.1",
    "from_commit": "abc123...",
    "to_commit": "def456...",
    "description": "Initial deploy",
    "applied_at": "2026-04-05T06:00:00Z",
    "applied_at_complete": "2026-04-05T06:08:22Z",
    "status": "applied"
  }
]
```

Possible `status` values: `applying`, `applied`, `error`, `rolledback`.
The sidecar appends an `applying` entry on `POST /upload/apply`, then `apply-update.sh`
updates it to `applied` (or `error`) upon completion.

---

## Extending the project

### Adding authentication to the sidecar

Currently the sidecar trusts any request from localhost. To add a shared secret:

1. Generate a token at sidecar startup and write it to `/run/iot-updater.token`
2. Cockpit page reads the token via `cockpit.file('/run/iot-updater.token').read()`
3. Page sends `Authorization: Bearer <token>` on every request
4. Sidecar validates it in `do_OPTIONS`/`do_POST`/`do_GET`

### Packaging as an RPM

The correct long-term approach for Fedora IoT:
1. Create an RPM spec at `packaging/cockpit-iot-updater.spec`
2. Include the Cockpit page in `/usr/share/cockpit/iot-updater/`
3. Include systemd units in `/usr/lib/systemd/system/`
4. Include scripts in `/usr/lib/iot-updater/`
5. `rpm-ostree install cockpit-iot-updater` survives future OS updates

### Adding rollback support

`apply-update.sh` could be extended with a `--rollback` flag:
```bash
rpm-ostree rollback
sleep 2
systemctl reboot
```
The Cockpit page could trigger this via a separate `POST /rollback` endpoint on the sidecar.
