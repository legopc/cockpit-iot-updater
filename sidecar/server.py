#!/usr/bin/env python3
"""
Cockpit IoT Updater — sidecar HTTP server
Binds to 127.0.0.1:8088. Receives chunked uploads, streams to disk,
triggers the iot-update.service after a complete upload.

Run as root (required for /var/tmp write + systemctl start).
"""

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
BUNDLE_PATH = Path("/var/tmp/iot43-update.iotupdate")
DELTA_PATH  = Path("/var/tmp/iot43-update.delta")
HISTORY_PATH = Path("/var/lib/iot-updater/history.json")
STATUS_PATH  = Path("/run/iot-update-status.json")

# Global state — only one concurrent update at a time
_state = {
    "stage": "idle",       # idle | uploading | extracting | queued | applying | rebooting | error
    "progress_pct": 0,
    "message": "Ready for upload.",
    "version_info": None,
    "error": None,
}
_state_lock = threading.Lock()


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
                # Clear stale error when the apply script signals idle/success
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
    """Pull version.json out of the .iotupdate tar without extracting the full delta."""
    try:
        with tarfile.open(bundle_path, "r:") as tar:
            member = tar.getmember("version.json")
            f = tar.extractfile(member)
            if f:
                return json.load(f)
    except Exception as e:
        return {"error": str(e)}
    return None


def trigger_apply(version_info: dict):
    """Start iot-update.service via systemctl. Called in a background thread."""
    set_state(stage="queued", progress_pct=0, message="Handing off to update service…")
    entry = {
        "version": version_info.get("version", "unknown"),
        "from_commit": version_info.get("from_commit", ""),
        "to_commit": version_info.get("to_commit", ""),
        "description": version_info.get("description", ""),
        "applied_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "status": "applying",
    }
    append_history(entry)

    result = subprocess.run(
        ["systemctl", "start", "iot-update.service"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        msg = result.stderr.strip() or "systemctl start failed"
        set_state(stage="error", message=msg, error=msg)
        # Update history entry status
        history = load_history()
        if history:
            history[-1]["status"] = "error"
            history[-1]["error"] = msg
            HISTORY_PATH.write_text(json.dumps(history, indent=2))


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
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Chunk-Index, X-Total-Chunks, X-Filename")
        self.end_headers()

    def do_GET(self):
        read_external_status()

        if self.path == "/status":
            self.send_json(200, get_state())

        elif self.path == "/history":
            self.send_json(200, load_history())

        elif self.path == "/version-preview":
            # Return version info for the last uploaded (but not yet applied) bundle
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
            DELTA_PATH.unlink(missing_ok=True)
            set_state(stage="idle", progress_pct=0, message="Upload cancelled.", version_info=None)
            self.send_json(200, {"ok": True})
        else:
            self.send_json(404, {"error": "Not found."})

    def _handle_upload_start(self):
        """Reset state before a new multi-chunk upload begins."""
        state = get_state()
        if state["stage"] not in ("idle", "error"):
            self.send_json(409, {"error": f"Cannot start upload in state: {state['stage']}"})
            return
        BUNDLE_PATH.unlink(missing_ok=True)
        DELTA_PATH.unlink(missing_ok=True)
        set_state(stage="uploading", progress_pct=0, message="Upload started.", version_info=None, error=None)
        self.send_json(200, {"ok": True})

    def _handle_upload(self):
        """Receive a single chunk and append it to BUNDLE_PATH."""
        state = get_state()
        if state["stage"] not in ("uploading", "idle"):
            self.send_json(409, {"error": f"Not in upload state: {state['stage']}"})
            return

        chunk_index = int(self.headers.get("X-Chunk-Index", 0))
        total_chunks = int(self.headers.get("X-Total-Chunks", 1))
        content_length = int(self.headers.get("Content-Length", 0))

        if content_length <= 0:
            self.send_json(400, {"error": "Empty chunk."})
            return

        # Stream chunk to disk
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
        set_state(
            stage="uploading",
            progress_pct=progress,
            message=f"Uploading… chunk {chunk_index + 1}/{total_chunks}"
        )

        # Last chunk — extract version.json immediately
        if chunk_index + 1 >= total_chunks:
            set_state(stage="extracting", progress_pct=100, message="Extracting version info…")
            version_info = extract_version_from_bundle(BUNDLE_PATH)
            if version_info and "error" not in version_info:
                set_state(
                    stage="idle",
                    progress_pct=100,
                    message=f"Bundle ready: v{version_info.get('version', '?')}. Review and confirm to apply.",
                    version_info=version_info,
                )
            else:
                err = (version_info or {}).get("error", "version.json missing or invalid")
                set_state(stage="error", message=f"Bundle error: {err}", error=err)
                self.send_json(422, {"error": err})
                return

        self.send_json(200, {"chunk": chunk_index, "progress": progress})

    def _handle_apply(self):
        """Confirm and kick off the actual OSTree apply."""
        state = get_state()
        if state["stage"] != "idle" or state.get("version_info") is None:
            self.send_json(409, {"error": "No ready bundle to apply."})
            return
        version_info = state["version_info"]
        threading.Thread(target=trigger_apply, args=(version_info,), daemon=True).start()
        self.send_json(200, {"ok": True, "version": version_info.get("version")})


def main():
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    server = http.server.HTTPServer((LISTEN_HOST, LISTEN_PORT), UpdateHandler)
    print(f"[iot-updater] Listening on {LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
