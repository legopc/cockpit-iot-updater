# Sidecar HTTP API Reference

The sidecar (`sidecar/server.py`) is a Python stdlib HTTP server bound to `127.0.0.1:8088`.
All endpoints are accessed via `cockpit.http(8088)` from the browser — never directly.

---

## GET /status

Returns the current upload/apply state and progress information.

**Response: 200 OK**

```json
{
  "stage":    "idle",
  "progress": 0,
  "message":  "",
  "error":    null
}
```

### stage values

| Stage | Meaning |
|-------|---------|
| `idle` | No upload or apply in progress |
| `uploading` | Bundle is being received in chunks |
| `verifying` | SHA-256 being verified, version.json being parsed |
| `staged` | Bundle received and verified; awaiting user confirmation to apply |
| `applying` | `iot-update.service` is running (skopeo + bootc switch) |
| `error` | An unrecoverable error occurred (see `error` field) |

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `stage` | string | One of the stage values above |
| `progress` | integer | 0–100; meaningful during `uploading` (bytes received %) |
| `message` | string | Human-readable status detail |
| `error` | string\|null | Error message if stage is `error`; null otherwise |
| `version` | object\|null | Parsed version.json content when stage is `staged` or later |

---

## GET /history

Returns the full update history log.

**Response: 200 OK**

```json
[
  {
    "version":    "v8",
    "description": "Previous release",
    "applied_at": "2025-04-01T10:00:00Z",
    "status":     "applied",
    "sha256":     "abc123..."
  }
]
```

History is persisted at `/var/lib/iot-updater/history.json`.
Entries are appended on each successful apply. Never auto-pruned.

---

## GET /bootc-status

Returns the current `bootc status` output parsed into booted/staged/rollback deployments.
Result is cached for 5 seconds.

**Response: 200 OK**

```json
{
  "booted": {
    "image":     "localhost/inferno-appliance:v8",
    "digest":    "sha256:abcdef...",
    "version":   "v8",
    "timestamp": "2025-04-01T10:00:00Z"
  },
  "staged":   null,
  "rollback": {
    "image":     "localhost/inferno-appliance:v7",
    "digest":    "sha256:123456...",
    "version":   "v7",
    "timestamp": "2025-03-01T10:00:00Z"
  }
}
```

Each of `booted`, `staged`, `rollback` is either an object (when a deployment exists in that slot)
or `null`. The UI hides the rollback button when `rollback` is null.

**Error Response: 500**

```json
{ "error": "bootc status failed: <stderr>" }
```

---

## GET /version-preview?file=<path>

Reads and returns `version.json` from the specified bundle path (must be on the device filesystem).
Used internally by the sidecar after upload completes — not typically called by the UI directly.

**Response: 200 OK** — contents of version.json as JSON object.

**Error Response: 400/500** if file not found or JSON invalid.

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
