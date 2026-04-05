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
STATUS_PATH  = Path("/run/iot-update-status.json")

# Global state — only one concurrent update at a time
_state = {
    "stage": "idle",       # idle | uploading | extracting | verifying | queued | applying | rebooting | error
    "progress_pct": 0,
    "message": "Ready for upload.",
    "version_info": None,
    "error": None,
}
_state_lock = threading.Lock()

# Cached bootc status
_bootc_cache = {"data": None, "ts": 0}
_bootc_lock  = threading.Lock()


def set_state(**kwargs):
    with _state_lock:
        _state.update(kwargs)


def get_state():
    with _state_lock:
        return dict(_state)


def read_external_status():
    """Merge status written by apply-update.sh if it exists."""
    try:
        if STATUS_PATH.exists():
            data = json.loads(STATUS_PATH.read_text())
            with _state_lock:
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
    HISTORY_PATH.write_text(json.dumps(history, indent=2))


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
    Extract image.tar from the bundle and verify its sha256 against version_info.
    Returns (ok, message).
    """
    expected = version_info.get("image_sha256", "")
    oci_file = version_info.get("oci_image_file", "")

    if not expected or not oci_file:
        return True, "No hash in version.json — skipping integrity check."

    try:
        h = hashlib.sha256()
        with tarfile.open(bundle_path, "r:") as tar:
            member = tar.getmember(oci_file)
            f = tar.extractfile(member)
            if not f:
                return False, f"Cannot extract {oci_file} from bundle"
            while True:
                chunk = f.read(4 * 1024 * 1024)
                if not chunk:
                    break
                h.update(chunk)
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


def get_bootc_status(force: bool = False) -> dict:
    """
    Run 'bootc status --format json' and return a simplified dict.
    Cached for 5 seconds to avoid hammering the system.
    """
    with _bootc_lock:
        now = time.time()
        if not force and _bootc_cache["data"] and (now - _bootc_cache["ts"]) < 5:
            return _bootc_cache["data"]

        try:
            result = subprocess.run(
                ["bootc", "status", "--format", "json"],
                capture_output=True, text=True, timeout=10
            )
            raw = json.loads(result.stdout)
            status = raw.get("status", {})

            def parse_slot(slot):
                if not slot:
                    return None
                img = slot.get("image", {})
                return {
                    "image":     img.get("image", {}).get("image", ""),
                    "digest":    img.get("imageDigest", ""),
                    "version":   img.get("version", ""),
                    "timestamp": img.get("timestamp", ""),
                }

            data = {
                "booted":   parse_slot(status.get("booted")),
                "staged":   parse_slot(status.get("staged")),
                "rollback": parse_slot(status.get("rollback")),
            }
        except Exception as e:
            data = {"error": str(e), "booted": None, "staged": None, "rollback": None}

        _bootc_cache["data"] = data
        _bootc_cache["ts"]   = now
        return data


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

    result = subprocess.run(
        ["systemctl", "start", "iot-update.service"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        msg = result.stderr.strip() or "systemctl start failed"
        set_state(stage="error", message=msg, error=msg)
        history = load_history()
        if history:
            history[-1]["status"] = "error"
            history[-1]["error"]  = msg
            HISTORY_PATH.write_text(json.dumps(history, indent=2))


def do_rollback():
    """Run bootc rollback --apply in a background thread."""
    set_state(stage="rebooting", progress_pct=100, message="Rolling back… device will reboot.")
    subprocess.run(["bootc", "rollback", "--apply"], capture_output=True)


class UpdateHandler(http.server.BaseHTTPRequestHandler):
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
            self.send_json(200, get_state())

        elif self.path == "/history":
            self.send_json(200, load_history())

        elif self.path == "/bootc-status":
            self.send_json(200, get_bootc_status())

        elif self.path == "/version-preview":
            state = get_state()
            if state.get("version_info"):
                self.send_json(200, state["version_info"])
            else:
                self.send_json(404, {"error": "No bundle uploaded yet."})

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
    server = http.server.HTTPServer((LISTEN_HOST, LISTEN_PORT), UpdateHandler)
    print(f"[iot-updater] Listening on {LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
