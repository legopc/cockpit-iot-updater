# Sidecar HTTP API Reference

The sidecar (`sidecar/server.py`) is a Python stdlib HTTP server bound to `127.0.0.1:8088`.
All endpoints are accessed via `cockpit.http(8088)` from the browser — never directly.

---

## Endpoint summary

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Service health check |
| GET | `/status` | Current upload/apply state |
| GET | `/history` | Update history log |
| GET | `/bootc-status` | Booted/staged/rollback deployment info |
| GET | `/version-preview` | Parsed version.json of uploaded bundle |
| GET | `/logs` | Tail of persistent update log |
| POST | `/upload/start` | Begin upload session |
| POST | `/upload` | Send one chunk |
| POST | `/upload/apply` | Confirm and apply bundle |
| POST | `/upload/cancel` | Abort/clear |
| POST | `/rollback` | Rollback to previous deployment |

---

## GET /health

Returns service liveness. Always returns 200 if the sidecar is running.

**Response: 200 OK**

```json
{ "ok": true, "service": "iot-updater", "stage": "idle" }
```

---

## GET /status

Returns the current upload/apply state and progress information.

**Response: 200 OK**

```json
{
  "stage":          "idle",
  "progress_pct":   0,
  "message":        "Ready for upload.",
  "version_info":   null,
  "error":          null,
  "started_at":     "2026-04-06T23:18:32Z",
  "last_update_at": "2026-04-06T23:18:32Z"
}
```

### stage values

| Stage | Meaning |
|-------|---------|
| `idle` | Ready for upload (or bundle ready to apply) |
| `uploading` | Bundle is being received in chunks |
| `extracting` | Reading version.json from bundle |
| `verifying` | SHA-256 being verified server-side |
| `queued` | Apply confirmed, handing off to iot-update.service |
| `applying` | `iot-update.service` is running (skopeo + bootc switch) |
| `rebooting` | Apply done, system is rebooting |
| `error` | An unrecoverable error occurred (see `error` field) |

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `stage` | string | One of the stage values above |
| `progress_pct` | integer | 0–100; meaningful during `uploading` |
| `message` | string | Human-readable status detail |
| `version_info` | object\|null | Parsed version.json when bundle is ready to apply |
| `error` | string\|null | Error message if stage is `error`; null otherwise |
| `started_at` | string | ISO 8601 UTC timestamp when the sidecar process started |
| `last_update_at` | string | ISO 8601 UTC timestamp of the last state change |

---

## GET /history

Returns the update history log (newest last).

**Response: 200 OK**

```json
[
  {
    "version":              "v13",
    "description":          "Inferno AoIP v13",
    "oci_image":            "localhost/inferno-appliance:v13",
    "sha256":               "abc123...",
    "applied_at":           "2026-04-06T19:00:00Z",
    "applied_at_complete":  "2026-04-06T19:05:33Z",
    "status":               "applied",
    "log_snippet":          null
  }
]
```

History is persisted at `/var/lib/iot-updater/history.json`.
Capped at **100 entries**; older entries are archived to `history-archive.json`.

On failures, `log_snippet` contains the last 30 lines of `update.log` at the time of failure.

### status values

| Value | Meaning |
|-------|---------|
| `applying` | In progress (transient) |
| `applied` | Successfully applied and rebooted |
| `dry_run` | Dry run completed (no reboot) |
| `error` | Apply failed (see `error` field) |

---

## GET /bootc-status

Returns the current `bootc status` output parsed into booted/staged/rollback deployments.
Result is cached for up to 10 seconds.

**Response: 200 OK**

```json
{
  "booted": {
    "image":     "localhost/inferno-appliance:v13",
    "digest":    "sha256:abcdef...",
    "version":   "43.20260405.0",
    "timestamp": "2026-04-06T17:19:11Z"
  },
  "staged":            null,
  "rollback": {
    "image":     "inferno-appliance:unknown",
    "digest":    "sha256:123456...",
    "version":   "43.20260404.0",
    "timestamp": "2026-04-05T10:37:47Z"
  },
  "cache_age_seconds": 0.3
}
```

`cache_age_seconds` indicates how old the cached data is. The cache is refreshed automatically
on apply/rollback transitions.

---

## GET /version-preview

Returns the parsed `version.json` of the currently uploaded (but not yet applied) bundle.

**Response: 200 OK** — contents of version.json.

**Error: 404** if no bundle has been uploaded yet.

---

## GET /logs

Returns the tail of the persistent update log at `/var/lib/iot-updater/update.log`.

**Query parameters:**
- `lines` (optional, default 100, max 500) — number of lines to return from end of file

**Response: 200 OK**

```json
{
  "lines": [
    "[2026-04-06T19:00:01Z] [START] apply-update.sh starting — bundle=/var/tmp/iot43-update.iotupdate",
    "[2026-04-06T19:00:02Z] [INFO] Disk preflight OK: 45231616 KB available in /var/tmp",
    "[2026-04-06T19:05:33Z] [SUCCESS] Update v13 applied — rebooting to localhost/inferno-appliance:v13"
  ],
  "path": "/var/lib/iot-updater/update.log"
}
```

Returns `{"lines": [], "path": "..."}` if the log file does not exist yet.

Log line format: `[ISO8601_TIMESTAMP] [LEVEL] message`

Log levels: `START`, `INFO`, `ERROR`, `SUCCESS`, `COMPLETE`, `DRY_RUN`

---

## POST /upload/start

Begins an upload session.

**Request body (JSON):**

```json
{
  "filename": "inferno-appliance-v9.iotupdate",
  "size":     2147483648
}
```

**Response: 200 OK**

```json
{ "ok": true }
```

**Error: 409 Conflict** if an upload or apply is already in progress.

Transitions state from `idle` → `uploading`.

---

## POST /upload

Sends one chunk of the bundle file. Chunks are appended in order to the landing file.

**Request:** raw binary body (up to ~8 MB per request)

**Response: 200 OK**

```json
{ "received": 8388608, "total": 2147483648 }
```

After all bytes received, the sidecar transitions to `verifying`:
- Streams through `image.tar` inside the tar to compute SHA-256 (in-memory, no extraction)
- Parses `version.json`

Then transitions to `staged`.

**Error: 409** if not in `uploading` state.

---

## POST /upload/apply

Confirms the staged bundle and starts the apply service.

**Request body:** empty or `{}`

**Response: 200 OK**

```json
{ "ok": true }
```

Transitions state `staged` → `applying`. Calls `systemctl start iot-update.service`.

The apply service (`iot-update.service`) runs `apply-update.sh` as root. When done it writes
`{stage: idle}` to `/var/lib/iot-updater/status.json`; the sidecar reads this on the next
`/status` poll and transitions back to `idle` before the device reboots.

**Error: 409** if not in `staged` state.

---

## POST /upload/cancel

Aborts the current upload or clears a staged/error state.

**Request body:** empty or `{}`

**Response: 200 OK**

```json
{ "ok": true }
```

Removes the partial/staged bundle file. Transitions any state → `idle`.

---

## POST /rollback

Executes `bootc rollback --apply`, which stages the rollback and immediately reboots.

**Request body:** empty or `{}`

**Response: 200 OK** (device will reboot; this response may not reach the browser)

```json
{ "ok": true, "message": "Rollback initiated, rebooting..." }
```

**Error: 400** if no rollback slot exists:

```json
{ "error": "No rollback available — only one deployment exists" }
```

**Error: 500** if `bootc rollback --apply` fails:

```json
{ "error": "bootc rollback failed: <stderr>" }
```

---

## Error responses

All endpoints return `{ "error": "message" }` with an appropriate HTTP status code on failure.
The sidecar never crashes on a handled error — it returns to `idle` or `error` state and
continues serving requests.

---

## Notes

- All JSON bodies use UTF-8 encoding.
- The sidecar is single-threaded (Python stdlib `BaseHTTPRequestHandler`). Concurrent requests
  are serialized. This is intentional — simultaneous uploads would corrupt state.
- `/bootc-status` is the only endpoint that spawns a subprocess (`bootc status`).
  All other endpoints are pure Python or file I/O.
