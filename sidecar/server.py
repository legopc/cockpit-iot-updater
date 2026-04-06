#!/usr/bin/env python3
"""
Cockpit IoT Updater — sidecar HTTP server
Binds to 127.0.0.1:8088. Receives chunked uploads, verifies integrity,
streams to disk, triggers the iot-update.service after a complete upload.

Run as root (required for /var/tmp write + systemctl start + bootc calls).
"""

import hashlib
import http.server
import json
import os
import subprocess
import tarfile
import threading
import time
from pathlib import Path

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8088
BUNDLE_PATH  = Path("/var/tmp/iot43-update.iotupdate")
HISTORY_PATH = Path("/var/lib/iot-updater/history.json")
LOG_PATH     = Path("/var/lib/iot-updater/update.log")
STATUS_PATH  = Path("/run/iot-update-status.json")
HISTORY_ARCHIVE_PATH = Path("/var/lib/iot-updater/history-archive.json")
HISTORY_MAX_ENTRIES  = 100

# Global state — only one concurrent update at a time
_state = {
    "stage": "idle",       # idle | uploading | extracting | verifying | queued | applying | rebooting | error
    "progress_pct": 0,
    "message": "Ready for upload.",
    "version_info": None,
    "error": None,
}
_state_lock = threading.Lock()
_started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
_last_state_change = _started_at

# Cached bootc status
_bootc_cache = {"data": None, "ts": 0}
_bootc_lock  = threading.Lock()


def set_state(**kwargs):
    global _last_state_change
    with _state_lock:
        _state.update(kwargs)
        _last_state_change = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def get_state():
    with _state_lock:
        return dict(_state)


def read_external_status():
    """Merge status written by apply-update.sh if it exists.
    Only applied when the sidecar is in a passive state (idle/error/rebooting)
    so that STATUS_PATH from a previous run does not clobber an active upload.
    """
    try:
        if STATUS_PATH.exists():
            data = json.loads(STATUS_PATH.read_text())
            with _state_lock:
                # Never let an old status file overwrite an active upload/verify session
                if _state["stage"] not in ("uploading", "extracting", "verifying"):
                    _state.update(data)
                    if data.get("stage") == "idle":
                        _state["error"] = None
    except Exception:
        pass


def load_history():
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not HISTORY_PATH.exists():
        return []
    try:
        return json.loads(HISTORY_PATH.read_text())
    except Exception:
        return []


def append_history(entry: dict):
    history = load_history()
    history.append(entry)
    if len(history) > HISTORY_MAX_ENTRIES:
        overflow = history[:-HISTORY_MAX_ENTRIES]
        history  = history[-HISTORY_MAX_ENTRIES:]
        try:
            if HISTORY_ARCHIVE_PATH.exists():
                archive = json.loads(HISTORY_ARCHIVE_PATH.read_text())
            else:
                archive = []
        except Exception:
            archive = []
        archive.extend(overflow)
        HISTORY_ARCHIVE_PATH.write_text(json.dumps(archive, indent=2))
    HISTORY_PATH.write_text(json.dumps(history, indent=2))


def rotate_log(max_lines: int = 500):
    """Keep log file under max_lines by trimming oldest entries."""
    try:
        if not LOG_PATH.exists():
            return
        lines = LOG_PATH.read_text().splitlines(keepends=True)
        if len(lines) > max_lines:
            LOG_PATH.write_text("".join(lines[-max_lines:]))
    except Exception:
        pass


def extract_version_from_bundle(bundle_path: Path) -> dict | None:
    """Pull version.json out of the .iotupdate tar without extracting the full image."""
    try:
        with tarfile.open(bundle_path, "r:") as tar:
            member = tar.getmember("version.json")
            f = tar.extractfile(member)
            if f:
                return json.load(f)
    except Exception as e:
        return {"error": str(e)}
    return None


def verify_bundle_hash(bundle_path: Path, version_info: dict) -> tuple[bool, str]:
    """
    Stream image.tar from the bundle and verify its sha256 against version_info.
    Uses pipe (streaming) mode so the full archive is never buffered in RAM —
    critical for ~2 GB OCI bundles.
    Returns (ok, message).
    """
    expected = version_info.get("image_sha256", "")
    oci_file = version_info.get("oci_image_file", "")

    if not expected or not oci_file:
        return True, "No hash in version.json — skipping integrity check."

    try:
        h = hashlib.sha256()
        found = False
        # r| = streaming pipe mode: members are read sequentially, no seeking,
        # no full-archive buffering. getmember() is not available in this mode;
        # iterate with next() until we find the target file.
        with tarfile.open(bundle_path, "r|") as tar:
            for member in tar:
                if member.name == oci_file:
                    f = tar.extractfile(member)
                    if not f:
                        return False, f"Cannot extract {oci_file} from bundle"
                    while True:
                        chunk = f.read(4 * 1024 * 1024)
                        if not chunk:
                            break
                        h.update(chunk)
                    found = True
                    break
                else:
                    # Skip non-target members without extracting (advances stream position)
                    tar.members = []
        if not found:
            return False, f"{oci_file} not found in bundle"
        actual = h.hexdigest()
        if actual != expected:
            return False, (
                f"SHA256 mismatch — bundle may be corrupt or tampered.\n"
                f"  expected: {expected}\n"
                f"  actual:   {actual}"
            )
        return True, actual
    except Exception as e:
        return False, f"Hash verification error: {e}"


def _parse_slot(slot):
    if not slot:
        return None
    img = slot.get("image", {})
    return {
        "image":     img.get("image", {}).get("image", ""),
        "digest":    img.get("imageDigest", ""),
        "version":   img.get("version", ""),
        "timestamp": img.get("timestamp", ""),
    }


def _run_bootc_status():
    """Run bootc status subprocess and update the cache. Called with lock held."""
    now = time.time()
    try:
        result = subprocess.run(
            ["/usr/bin/bootc", "status", "--format", "json"],
            capture_output=True, text=True, timeout=8
        )
        raw = json.loads(result.stdout)
        status = raw.get("status", {})
        data = {
            "booted":   _parse_slot(status.get("booted")),
            "staged":   _parse_slot(status.get("staged")),
            "rollback": _parse_slot(status.get("rollback")),
        }
    except Exception as e:
        # Preserve stale cache on error rather than replacing with error dict
        if _bootc_cache["data"]:
            return
        data = {"error": str(e), "booted": None, "staged": None, "rollback": None}
    _bootc_cache["data"] = data
    _bootc_cache["ts"]   = now


def get_bootc_status(force: bool = False) -> dict:
    """
    Return bootc status dict. Cached for 10 seconds.
    Uses non-blocking lock acquisition: if bootc is already running in another
    thread, returns stale cached data immediately rather than blocking.
    """
    now = time.time()
    # Fast path: return cache if still fresh
    if not force and _bootc_cache["data"] and (now - _bootc_cache["ts"]) < 10:
        return _bootc_cache["data"]

    # Try to acquire lock without blocking; if another thread is already running
    # bootc, return whatever cached data we have.
    acquired = _bootc_lock.acquire(blocking=False)
    if not acquired:
        return _bootc_cache["data"] or {
            "error": "bootc query in progress", "booted": None,
            "staged": None, "rollback": None
        }
    try:
        # Re-check cache now that we hold the lock
        now = time.time()
        if not force and _bootc_cache["data"] and (now - _bootc_cache["ts"]) < 10:
            return _bootc_cache["data"]
        _run_bootc_status()
        return _bootc_cache["data"]
    finally:
        _bootc_lock.release()


def trigger_apply(version_info: dict):
    """Start iot-update.service via systemctl. Called in a background thread."""
    set_state(stage="queued", progress_pct=0, message="Handing off to update service…")
    entry = {
        "version":     version_info.get("version", "unknown"),
        "description": version_info.get("description", ""),
        "oci_image":   version_info.get("oci_image_name", ""),
        "sha256":      version_info.get("image_sha256", ""),
        "applied_at":  time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "status":      "applying",
    }
    append_history(entry)
    threading.Thread(target=lambda: get_bootc_status(force=True), daemon=True).start()

    try:
        result = subprocess.run(
            ["systemctl", "start", "iot-update.service"],
            capture_output=True, text=True, timeout=7200
        )
    except subprocess.TimeoutExpired:
        msg = "iot-update.service timed out after 2 hours"
        set_state(stage="error", message=msg, error=msg)
        history = load_history()
        if history:
            history[-1]["status"] = "error"
            history[-1]["error"]  = msg
            HISTORY_PATH.write_text(json.dumps(history, indent=2))
        return
    if result.returncode != 0:
        msg = result.stderr.strip() or "systemctl start failed"
        # Re-read history: apply-update.sh may have already written "applied"
        # before triggering a reboot, which causes systemd to cancel the job
        # and return a non-zero exit code here — that is not an error.
        history = load_history()
        if history and history[-1].get("status") in ("applied", "dry_run"):
            set_state(stage="rebooting", progress_pct=100,
                      message="Update applied — system is rebooting…")
            return
        set_state(stage="error", message=msg, error=msg)
        if history:
            # Read last 30 log lines to attach to history entry
            log_snippet = []
            try:
                if LOG_PATH.exists():
                    log_lines = LOG_PATH.read_text().splitlines()
                    log_snippet = log_lines[-30:]
            except Exception:
                pass
            history[-1]["status"] = "error"
            history[-1]["error"]  = msg
            if log_snippet:
                history[-1]["log_snippet"] = log_snippet
            HISTORY_PATH.write_text(json.dumps(history, indent=2))


def do_rollback():
    """Run bootc rollback --apply in a background thread."""
    set_state(stage="rebooting", progress_pct=100, message="Rolling back… device will reboot.")
    threading.Thread(target=lambda: get_bootc_status(force=True), daemon=True).start()
    subprocess.run(["bootc", "rollback", "--apply"], capture_output=True)


class UpdateHandler(http.server.BaseHTTPRequestHandler):
    timeout = 30  # kill stalled connections after 30s (inherits to socket timeout)

    def log_message(self, fmt, *args):
        print(f"[sidecar] {self.address_string()} - {fmt % args}")

    def send_json(self, code: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers",
                         "Content-Type, X-Chunk-Index, X-Total-Chunks, X-Filename")
        self.end_headers()

    def do_GET(self):
        read_external_status()

        if self.path == "/status":
            s = get_state()
            s["started_at"] = _started_at
            s["last_update_at"] = _last_state_change
            self.send_json(200, s)

        elif self.path == "/history":
            self.send_json(200, load_history())

        elif self.path == "/bootc-status":
            data = get_bootc_status()
            age = round(time.time() - _bootc_cache["ts"], 1) if _bootc_cache["ts"] else None
            self.send_json(200, {**data, "cache_age_seconds": age})

        elif self.path == "/version-preview":
            state = get_state()
            if state.get("version_info"):
                self.send_json(200, state["version_info"])
            else:
                self.send_json(404, {"error": "No bundle uploaded yet."})

        elif self.path.startswith("/logs"):
            # Parse ?lines=N query param (default 100, max 500)
            lines_param = 100
            if "?" in self.path:
                qs = self.path.split("?", 1)[1]
                for part in qs.split("&"):
                    if part.startswith("lines="):
                        try:
                            lines_param = min(int(part[6:]), 500)
                        except ValueError:
                            pass
            try:
                if LOG_PATH.exists():
                    all_lines = LOG_PATH.read_text().splitlines()
                    tail = all_lines[-lines_param:]
                else:
                    tail = []
            except Exception:
                tail = []
            self.send_json(200, {"lines": tail, "path": str(LOG_PATH)})

        elif self.path == "/health":
            self.send_json(200, {"ok": True, "service": "iot-updater", "stage": get_state()["stage"]})

        else:
            self.send_json(404, {"error": "Not found."})

    def do_POST(self):
        if self.path == "/upload":
            self._handle_upload()
        elif self.path == "/upload/start":
            self._handle_upload_start()
        elif self.path == "/upload/apply":
            self._handle_apply()
        elif self.path == "/upload/cancel":
            BUNDLE_PATH.unlink(missing_ok=True)
            set_state(stage="idle", progress_pct=0, message="Upload cancelled.",
                      version_info=None, error=None)
            self.send_json(200, {"ok": True})
        elif self.path == "/rollback":
            self._handle_rollback()
        else:
            self.send_json(404, {"error": "Not found."})

    def _handle_upload_start(self):
        state = get_state()
        if state["stage"] not in ("idle", "error"):
            self.send_json(409, {"error": f"Cannot start upload in state: {state['stage']}"})
            return
        BUNDLE_PATH.unlink(missing_ok=True)
        # Clear stale status file from previous run so it cannot bleed into this session
        STATUS_PATH.unlink(missing_ok=True)
        set_state(stage="uploading", progress_pct=0, message="Upload started.",
                  version_info=None, error=None)
        self.send_json(200, {"ok": True})

    def _handle_upload(self):
        state = get_state()
        if state["stage"] not in ("uploading", "idle"):
            self.send_json(409, {"error": f"Not in upload state: {state['stage']}"})
            return

        chunk_index  = int(self.headers.get("X-Chunk-Index", 0))
        total_chunks = int(self.headers.get("X-Total-Chunks", 1))
        content_length = int(self.headers.get("Content-Length", 0))

        # Validate chunk headers
        if total_chunks <= 0 or chunk_index < 0 or chunk_index >= total_chunks:
            self.send_json(400, {"error": f"Invalid chunk headers: index={chunk_index} total={total_chunks}"})
            return

        if content_length <= 0:
            self.send_json(400, {"error": "Empty chunk."})
            return

        mode = "ab" if chunk_index > 0 else "wb"
        with open(BUNDLE_PATH, mode) as f:
            remaining = content_length
            while remaining > 0:
                chunk_size = min(remaining, 4 * 1024 * 1024)
                data = self.rfile.read(chunk_size)
                if not data:
                    break
                f.write(data)
                remaining -= len(data)

        # Restrict bundle file permissions — it contains a full OCI image
        if chunk_index == 0:
            try:
                os.chmod(BUNDLE_PATH, 0o600)
            except Exception:
                pass

        progress = int(((chunk_index + 1) / total_chunks) * 100)
        set_state(stage="uploading", progress_pct=progress,
                  message=f"Uploading… chunk {chunk_index + 1}/{total_chunks}")

        if chunk_index + 1 >= total_chunks:
            set_state(stage="extracting", progress_pct=100, message="Reading bundle metadata…")
            version_info = extract_version_from_bundle(BUNDLE_PATH)

            if not version_info or "error" in version_info:
                err = (version_info or {}).get("error", "version.json missing or invalid")
                set_state(stage="error", message=f"Bundle error: {err}", error=err)
                self.send_json(422, {"error": err})
                return

            # Verify hash (streams through image.tar inside the tar — no temp extraction needed)
            if version_info.get("image_sha256"):
                set_state(stage="verifying", progress_pct=100,
                          message="Verifying bundle integrity (sha256)…")
                ok, result = verify_bundle_hash(BUNDLE_PATH, version_info)
                if not ok:
                    BUNDLE_PATH.unlink(missing_ok=True)
                    set_state(stage="error", message=result, error=result)
                    self.send_json(422, {"error": result})
                    return
            else:
                result = "(no hash in bundle)"

            set_state(
                stage="idle",
                progress_pct=100,
                message=f"Bundle ready: v{version_info.get('version', '?')}. Review and confirm to apply.",
                version_info=version_info,
                error=None,
            )

        self.send_json(200, {"chunk": chunk_index, "progress": progress})

    def _handle_apply(self):
        state = get_state()
        if state["stage"] != "idle" or state.get("version_info") is None:
            self.send_json(409, {"error": "No ready bundle to apply."})
            return
        version_info = state["version_info"]
        threading.Thread(target=trigger_apply, args=(version_info,), daemon=True).start()
        self.send_json(200, {"ok": True, "version": version_info.get("version")})

    def _handle_rollback(self):
        """Queue a bootc rollback and reboot."""
        state = get_state()
        if state["stage"] not in ("idle", "error"):
            self.send_json(409, {"error": f"Cannot rollback while in state: {state['stage']}"})
            return

        bs = get_bootc_status(force=True)
        if not bs.get("rollback"):
            self.send_json(409, {"error": "No rollback deployment available."})
            return

        rollback_image = bs["rollback"].get("image", "previous image")
        threading.Thread(target=do_rollback, daemon=True).start()
        self.send_json(200, {"ok": True, "rolling_back_to": rollback_image})


def main():
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    rotate_log()
    server = http.server.ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), UpdateHandler)
    print(f"[iot-updater] Listening on {LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
