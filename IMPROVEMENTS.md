# cockpit-iot-updater — Improvement Roadmap

> Generated 2026-04-06 after v10→v13→v10→v13 upgrade/rollback cycle audit.
> 4 agents audited: sidecar `server.py`, `apply-update.sh`, Cockpit UI, systemd units & tooling.

---

## 🔴 CRITICAL — Fix Before Next Release

### C-1 · Command injection in `apply-update.sh` `fail()` / `mark_complete()`
**File:** `scripts/apply-update.sh` lines 33–58  
Shell variables (`$msg`, `$status`) are interpolated directly into inline Python strings executed by bash.
A message containing quotes or `$()` breaks Python syntax — or can inject arbitrary code.  
**Fix:** Pass values via environment variables:
```bash
MSG="$msg" python3 -c "import os,json; msg=os.environ['MSG']; ..."
```

### C-2 · Tar path traversal in `apply-update.sh`
**File:** `scripts/apply-update.sh` lines 128–129  
`oci_image_file` from `version.json` is passed directly to `tar -xf ... "$OCI_IMAGE_FILE"` without
validation. A malicious bundle with `oci_image_file: "../../../etc/passwd"` could write outside the
work directory.  
**Fix:** Validate the filename contains no slashes before use:
```bash
[[ "$OCI_IMAGE_FILE" == */* ]] && fail "invalid oci_image_file path in version.json"
```

### C-3 · No authentication on sidecar HTTP endpoints
**File:** `sidecar/server.py` — all POST endpoints  
Any local process can upload bundles, trigger updates, and initiate rollbacks. Cockpit proxies
requests but there is no session token or Unix peer-UID check.  
**Fix:** Generate a random token on startup; require it as an `X-Updater-Token` header. The
Cockpit page fetches the token once on load from a new `GET /token` endpoint (auth by Cockpit
session itself).

### C-4 · Credentials / personal paths in documentation
**File:** `DEPLOYMENT-V9.md` line 12  
A literal password and an absolute personal home-directory path are checked into a public repository.  
**Fix:** Replace immediately with placeholders. Rotate the credential if it is still active.

---

## 🟠 HIGH — Address in Near-Term (v14)

### H-1 · systemd unit security hardening (`iot-updater.service`)
`ProtectSystem=false`, `NoNewPrivileges=false`, no `CapabilityBoundingSet`, no syscall filter.
A root daemon with no restrictions is a full-system-compromise risk.  
**Fix:**
```ini
ProtectSystem=strict
ReadWritePaths=/var/lib/iot-updater /var/tmp /run
NoNewPrivileges=true
CapabilityBoundingSet=CAP_SYS_BOOT CAP_NET_BIND_SERVICE
```

### H-2 · No timeout on `iot-update.service` (`TimeoutStartSec=0`)
A corrupted or stuck bundle could block the oneshot service indefinitely.  
**Fix:** `TimeoutStartSec=1800` (30-min ceiling for 2 GB+ OCI bundles).

### H-3 · No disk-space pre-flight check in `apply-update.sh`
Extracting a 2 GB OCI tar to `/var/tmp` fails with a cryptic error if the disk is full.  
**Fix:** Check available space before extraction and fail early with a clear message.

### H-4 · No `SIGTERM` trap / cleanup in `apply-update.sh`
If `iot-update.service` is stopped mid-run, the work directory and partial OCI tars accumulate in
`/var/tmp`.  
**Fix:** `trap 'rm -rf "$WORK_DIR"; exit 130' TERM INT` near the top of the script.

### H-5 · `trigger_apply()` has no subprocess timeout
`systemctl start iot-update.service` is called blocking with no timeout. If systemd hangs, the
thread blocks forever.  
**File:** `sidecar/server.py` line 226  
**Fix:** `subprocess.run([...], capture_output=True, text=True, timeout=7200)`; handle
`subprocess.TimeoutExpired`.

### H-6 · No reboot-reconnect UX in Cockpit page
After apply/rollback the device reboots. The UI has no countdown, no reconnect prompt, and no
auto-refresh. The user stares at an unresponsive page.  
**File:** `cockpit-page/update.js`  
**Fix:** Detect 5 consecutive `/status` poll failures → show "Device is rebooting… reconnecting in
Xs" countdown with automatic page refresh.

### H-7 · Upload session orphaned when browser tab closes mid-upload
Sidecar stays in `uploading` state indefinitely; next session cannot upload.  
**File:** `cockpit-page/update.js`  
**Fix:** `window.addEventListener('beforeunload', () => api.post('/upload/cancel'))`.

### H-8 · Bundle integrity check silently skipped when `image_sha256` is absent
Both the sidecar and `apply-update.sh` skip SHA-256 verification without warning the user.  
**Fix:** Emit a clear error (or at minimum a loud warning) when `image_sha256` is missing from
`version.json`. It should always be present.

### H-9 · `install.sh` sets 755 permissions on root-only scripts
`server.py` and `apply-update.sh` are world-readable, exposing internal logic.  
**Fix:** `install -m 700` (or 750 with a dedicated `iot-updater` group) for both files.

### H-10 · No bundle signature / authenticity verification
Bundles are integrity-checked (SHA-256) but not authenticated. A compromised upload path can
substitute the bundle undetected.  
**Fix:** Add HMAC-SHA-256 or GPG signing to the bundle format; verify in `apply-update.sh` before
extraction begins.

---

## 🟡 MEDIUM — Plan for Subsequent Sprint

### M-1 · History file grows unbounded
`history.json` is never rotated. After hundreds of updates it becomes slow to load and wastes disk.  
**Fix:** Keep the latest 100 entries; rotate older ones to `history-archive.json`.

### M-2 · `write_status()` in `apply-update.sh` is non-atomic
A simple shell redirect can produce malformed JSON if interrupted mid-write.  
**Fix:** Write to a `.tmp` file, then `mv` atomically.

### M-3 · `ARCHITECTURE.md` has the wrong `status.json` path
Docs say `/var/lib/iot-updater/status.json`; code uses `/run/iot-update-status.json`.  
**Fix:** Update the docs to match the code.

### M-4 · Repeated JSON parsing in `apply-update.sh` (5 separate Python processes)
`version.json` is parsed 5+ times via separate `python3 -c` invocations.  
**Fix:** Parse once in a single Python heredoc and export all values as shell variables.

### M-5 · Global mutable state in Cockpit JS — no state machine
Variables (`selectedFile`, `versionPreview`, etc.) are bare globals; state leaks between uploads
and error recoveries.  
**Fix:** Wrap in a `state = {}` object with a `resetState()` helper called at every flow start.

### M-6 · No "Applying… device will reboot" feedback after clicking Apply
The Apply button does nothing visually after being clicked; the user may double-click.  
**Fix:** Disable the button immediately, show "Applying…" text, start reboot countdown once
`/status` reaches `rebooting`.

### M-7 · Progress bar stuck at 100% during SHA-256 verification phase
After upload completes the bar freezes with no indication verification is running.  
**Fix:** Introduce a distinct `verifying` stage in the sidecar with its own progress percentage.

### M-8 · Rollback button styled as "danger" (red) — misleading
Rollback is safe and reversible; red implies destructive / data-loss action.  
**Fix:** Change to `btn-warning` (yellow/orange).

### M-9 · Polling timers never cleared on Cockpit plugin unload
`statusPoller` and `bootcPoller` keep firing after the user navigates away from the plugin.  
**Fix:** Clear both in a `beforeunload` / Cockpit page-hide handler.

### M-10 · `BUNDLE_PATH` in `/var/tmp` is world-readable
A 2 GB OCI bundle written to `/var/tmp` with default umask is readable by any local user.  
**Fix:** `chmod 600` immediately after first write, or move bundle staging to
`/var/lib/iot-updater/` (root-owned, mode 700).

### M-11 · `make-oci-bundle.sh`: no validation of exported tar before bundling
`podman save` can silently produce a partial file if interrupted.  
**Fix:** Run `tar -tf` on the exported tar to verify structure before SHA-256 and packaging.

### M-12 · Bootc status cache has no freshness indicator in API response
Clients cannot tell whether `/bootc-status` data is 0.1 s or 9.9 s old.  
**Fix:** Add `cache_age_seconds` to the response.

### M-13 · `X-Chunk-Index` / `X-Total-Chunks` headers not validated in sidecar
Negative or out-of-range values cause logic errors in progress calculation.  
**File:** `sidecar/server.py` lines 333–334  
**Fix:** Validate `0 <= chunk_index < total_chunks` and `total_chunks > 0` before use.

### M-14 · Version comparison in UI does not handle semver pre-releases
`versionCompare()` splits on `.` and compares as integers; fails on `v1.0.0-rc1` style tags.  
**Fix:** Normalise tags (strip leading `v`), handle pre-release suffixes correctly.

### M-15 · `ConditionPathExists` on `iot-update.service` is fragile
If the system reboots after the bundle is queued but before the service starts, the condition file
in `/var/tmp` is gone and the update is silently skipped.  
**Fix:** Use a persistent marker file in `/var/lib/iot-updater/` instead of `/var/tmp/`.

---

## 🟢 LOW / NICE-TO-HAVE

| ID | Area | Item |
|----|------|------|
| L-1 | Sidecar | Add `/health` endpoint for monitoring / orchestration |
| L-2 | Sidecar | Add `started_at` / `last_update_at` timestamps to `/status` response |
| L-3 | Sidecar | Standardise error response format (`{"error":"…"}` everywhere) |
| L-4 | Sidecar | Force bootc status cache refresh on apply/rollback state transitions |
| L-5 | apply-update.sh | Capture `bootc switch` / `skopeo` stderr into the status message for richer diagnostics |
| L-6 | apply-update.sh | Emit a clear warning banner on version downgrades (don't fail, just warn) |
| L-7 | UI | Add "copy to clipboard" button for SHA-256 in the history table |
| L-8 | UI | Dark mode support (`prefers-color-scheme: dark`) |
| L-9 | UI | Show "Apply and Reboot" (not just "Apply") for non-dry-run bundles |
| L-10 | UI | Add timeout and "Could not load — Retry" button to history card |
| L-11 | UI | Touch-friendly button sizing (≥ 44 px height, WCAG 2.1 AA) |
| L-12 | Tooling | `make-oci-bundle.sh --archive`: validate it is a valid tar before copying |
| L-13 | Tooling | Store podman image digest in `version.json` for full reproducibility |
| L-14 | Docs | Expand rollback gotchas — note that `/etc` state is not rolled back |
| L-15 | Docs | Clarify minimum bootc / Fedora IoT version requirements |
| L-16 | Systemd | Explicit `StandardOutput=journal` / `StandardError=journal` in both units |
| L-17 | Systemd | Add `After=systemd-tmpfiles-setup.service` to `iot-update.service` |

---

## Summary

| Severity | Count |
|----------|-------|
| 🔴 Critical | 4 |
| 🟠 High | 10 |
| 🟡 Medium | 15 |
| 🟢 Low / Nice-to-have | 17 |
| **Total** | **46** |

### Suggested v14 Scope
Fix all Critical + top High items before the next production build:

- **C-1** command injection fix in `apply-update.sh`
- **C-2** tar path traversal validation
- **C-4** credential / path scrub from `DEPLOYMENT-V9.md`
- **H-1** systemd unit security hardening
- **H-2** service timeout (`TimeoutStartSec=1800`)
- **H-3** disk-space pre-flight check
- **H-4** SIGTERM trap and cleanup
- **H-6** UI reconnect / reboot countdown
- **H-7** `beforeunload` upload cancel
- **H-9** script file permissions (`chmod 700`)
