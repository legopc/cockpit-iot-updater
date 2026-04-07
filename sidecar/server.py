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
import secrets
import shutil
import subprocess
import tarfile
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8088
SESSION_TOKEN = secrets.token_hex(32)
BUNDLE_PATH       = Path("/var/tmp/iot43-update.iotupdate")
BUNDLE_READY_PATH = Path("/var/lib/iot-updater/bundle-ready")
HISTORY_PATH = Path("/var/lib/iot-updater/history.json")
LOG_PATH     = Path("/var/lib/iot-updater/update.log")
STATUS_PATH  = Path("/run/iot-update-status.json")
HISTORY_ARCHIVE_PATH = Path("/var/lib/iot-updater/history-archive.json")
AUDIT_LOG_PATH = Path("/var/lib/iot-updater/audit.log")
MANIFEST_CONFIG_PATH = Path("/var/lib/iot-updater/manifest.json")
HISTORY_MAX_ENTRIES  = 100
REQUIRED_DISK_BYTES  = 6 * 1024 ** 3  # 6 GB: bundle + extraction headroom
FETCH_CHUNK_SIZE = 4 * 1024 * 1024  # 4 MB streaming chunks

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

# Per-endpoint rate limiting (in-memory, resets on restart)
_rate_limits: dict[str, list] = {}
_rate_lock = threading.Lock()


def _check_rate_limit(endpoint: str, max_requests: int, window_seconds: float) -> bool:
    """Return True if the request is allowed, False if rate limited."""
    now = time.monotonic()
    with _rate_lock:
        timestamps = _rate_limits.setdefault(endpoint, [])
        # Prune timestamps outside the window
        cutoff = now - window_seconds
        _rate_limits[endpoint] = [t for t in timestamps if t > cutoff]
        if len(_rate_limits[endpoint]) >= max_requests:
            return False
        _rate_limits[endpoint].append(now)
        return True


def set_state(**kwargs):
    global _last_state_change
    with _state_lock:
        _state.update(kwargs)
        _last_state_change = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def get_state():
    with _state_lock:
        return dict(_state)


def audit(endpoint: str, outcome: str, detail: str = ""):
    """Append a single structured line to the audit log. Never raises."""
    try:
        AUDIT_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = f"{ts} {endpoint} {outcome}"
        if detail:
            line += f" — {detail}"
        with open(AUDIT_LOG_PATH, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


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


def load_manifest_config() -> dict:
    """Read manifest config from MANIFEST_CONFIG_PATH, return {} if missing/invalid."""
    try:
        if MANIFEST_CONFIG_PATH.exists():
            return json.loads(MANIFEST_CONFIG_PATH.read_text())
    except Exception:
        pass
    return {}


def save_manifest_config(cfg: dict):
    """Write manifest config to MANIFEST_CONFIG_PATH, creating parent dirs as needed."""
    MANIFEST_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_CONFIG_PATH.write_text(json.dumps(cfg, indent=2))


def maybe_capture_manifest_url(version_info: dict):
    """If version_info contains manifest_url and no URL is configured yet, save it."""
    manifest_url = version_info.get("manifest_url", "").strip()
    if not manifest_url:
        return
    cfg = load_manifest_config()
    if not cfg.get("url"):
        cfg.setdefault("check_interval_hours", 24)
        cfg.setdefault("last_checked", None)
        cfg.setdefault("last_seen_version", None)
        cfg["url"] = manifest_url
        save_manifest_config(cfg)


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
        "bundle_type": version_info.get("bundle_type", "full"),
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
        self.send_header("Access-Control-Allow-Origin", "127.0.0.1")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "127.0.0.1")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers",
                         "Content-Type, X-Session-Token, X-Chunk-Index, X-Total-Chunks, X-Filename")
        self.send_header("Access-Control-Max-Age", "3600")
        self.end_headers()

    def _check_origin(self) -> bool:
        """Return True if Origin is acceptable, False (and send 403) if not."""
        origin = self.headers.get("Origin", "")
        if origin and origin not in ("null", "127.0.0.1", ""):
            self.send_json(403, {"error": "Forbidden"})
            return False
        return True

    def _check_session_token(self) -> bool:
        """Return True if X-Session-Token is valid, False (and send 403) if not."""
        token = self.headers.get("X-Session-Token", "")
        if not token or token != SESSION_TOKEN:
            self.send_json(403, {"error": "Invalid or missing session token"})
            return False
        return True

    def do_GET(self):
        if not self._check_origin():
            return
        read_external_status()

        if self.path == "/session-token":
            self.send_json(200, {"token": SESSION_TOKEN})

        elif self.path == "/status":
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

        elif self.path == "/check-update":
            cfg = load_manifest_config()
            url = cfg.get("url", "").strip()
            if not url:
                self.send_json(200, {"available": False, "reason": "no manifest configured"})
                return
            try:
                req = urllib.request.Request(
                    url,
                    headers={"User-Agent": "cockpit-iot-updater/1.0", "Accept": "application/json"}
                )
                with urllib.request.urlopen(req, timeout=10) as resp:
                    manifest = json.loads(resp.read().decode())
            except Exception as e:
                self.send_json(200, {"available": False, "error": str(e)})
                return
            history = load_history()
            if not history:
                self.send_json(200, {"available": False, "reason": "no current version"})
                return
            current_version = history[-1].get("version", "")
            manifest_version = manifest.get("version", "")
            cfg["last_checked"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            cfg["last_seen_version"] = manifest_version
            save_manifest_config(cfg)
            if manifest_version and manifest_version != current_version:
                self.send_json(200, {
                    "available": True,
                    "version":     manifest_version,
                    "bundle_url":  manifest.get("bundle_url", ""),
                    "description": manifest.get("description", ""),
                    "build_date":  manifest.get("build_date", ""),
                })
            else:
                self.send_json(200, {"available": False})

        elif self.path == "/version-preview":
            state = get_state()
            if state.get("version_info"):
                info = dict(state["version_info"])
                bundle_type = info.get("bundle_type", "full")
                info["bundle_type"] = bundle_type
                info["signed"] = "signature" in info
                if bundle_type == "delta":
                    info["base_version"] = info.get("base_version", "")
                    info["base_sha256"] = info.get("base_sha256", "")
                valid_until = info.get("valid_until")
                if valid_until:
                    try:
                        expiry_dt = datetime.fromisoformat(valid_until)
                        if expiry_dt.tzinfo is None:
                            expiry_dt = expiry_dt.replace(tzinfo=timezone.utc)
                        now_utc = datetime.now(timezone.utc)
                        if now_utc > expiry_dt:
                            self.send_json(409, {
                                "error": "Bundle has expired",
                                "expired": True,
                                "valid_until": valid_until,
                            })
                            return
                        info["days_remaining"] = (expiry_dt.date() - now_utc.date()).days
                    except (ValueError, TypeError):
                        pass
                self.send_json(200, info)
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

        elif self.path.startswith("/audit"):
            lines_param = 100
            if "?" in self.path:
                qs = self.path.split("?", 1)[1]
                for part in qs.split("&"):
                    if part.startswith("lines="):
                        try:
                            lines_param = min(int(part[6:]), 1000)
                        except ValueError:
                            pass
            try:
                if AUDIT_LOG_PATH.exists():
                    all_lines = AUDIT_LOG_PATH.read_text().splitlines()
                    tail = all_lines[-lines_param:]
                else:
                    tail = []
            except Exception:
                tail = []
            self.send_json(200, {"lines": tail, "path": str(AUDIT_LOG_PATH)})

        elif self.path == "/disk-space":
            usage = shutil.disk_usage("/var/tmp")
            self.send_json(200, {
                "available_bytes": usage.free,
                "available_gb": round(usage.free / 1024 ** 3, 1),
                "required_bytes": REQUIRED_DISK_BYTES,
                "required_gb": round(REQUIRED_DISK_BYTES / 1024 ** 3, 1),
                "ok": usage.free >= REQUIRED_DISK_BYTES
            })

        elif self.path == "/manifest-config":
            self.send_json(200, load_manifest_config())

        else:
            self.send_json(404, {"error": "Not found."})

    def do_POST(self):
        if not self._check_origin():
            return
        if not self._check_session_token():
            return
        if self.path == "/upload":
            self._handle_upload()
        elif self.path == "/upload/start":
            self._handle_upload_start()
        elif self.path == "/upload/apply":
            self._handle_apply()
        elif self.path == "/upload/cancel":
            BUNDLE_PATH.unlink(missing_ok=True)
            BUNDLE_READY_PATH.unlink(missing_ok=True)
            set_state(stage="idle", progress_pct=0, message="Upload cancelled.",
                      version_info=None, error=None)
            audit("/upload/cancel", "ok")
            self.send_json(200, {"ok": True})
        elif self.path == "/rollback":
            self._handle_rollback()
        elif self.path == "/fetch-url":
            self._handle_fetch_url()
        elif self.path == "/manifest-config":
            self._handle_manifest_config()
        else:
            self.send_json(404, {"error": "Not found."})

    def _handle_manifest_config(self):
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length <= 0:
            self.send_json(400, {"error": "Empty request body."})
            return
        try:
            payload = json.loads(self.rfile.read(content_length))
        except Exception:
            self.send_json(400, {"error": "Invalid JSON body."})
            return
        url = payload.get("url", "").strip()
        if not url:
            self.send_json(400, {"error": "Missing 'url' field."})
            return
        cfg = load_manifest_config()
        cfg["url"] = url
        cfg["check_interval_hours"] = int(payload.get("check_interval_hours", cfg.get("check_interval_hours", 24)))
        cfg.setdefault("last_checked", None)
        cfg.setdefault("last_seen_version", None)
        save_manifest_config(cfg)
        audit("/manifest-config", "ok", url[:120])
        self.send_json(200, {"ok": True})

    def _handle_upload_start(self):
        if not _check_rate_limit("/upload/start", 10, 60):
            audit("rate_limited", "/upload/start")
            self.send_json(429, {"error": "Rate limit exceeded. Try again later."})
            return
        state = get_state()
        if state["stage"] not in ("idle", "error"):
            self.send_json(409, {"error": f"Cannot start upload in state: {state['stage']}"})
            return
        # Pre-flight disk space check
        free = shutil.disk_usage("/var/tmp").free
        if free < REQUIRED_DISK_BYTES:
            free_gb = round(free / 1024 ** 3, 1)
            req_gb = round(REQUIRED_DISK_BYTES / 1024 ** 3, 1)
            self.send_json(507, {"error": f"Insufficient disk space in /var/tmp: {free_gb} GB free, {req_gb} GB required"})
            return
        BUNDLE_PATH.unlink(missing_ok=True)
        BUNDLE_READY_PATH.unlink(missing_ok=True)
        # Clear stale status file from previous run so it cannot bleed into this session
        STATUS_PATH.unlink(missing_ok=True)
        set_state(stage="uploading", progress_pct=0, message="Upload started.",
                  version_info=None, error=None)
        audit("/upload/start", "ok")
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
                audit("/upload", "error", err[:120])
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
                    audit("/upload", "error", result[:120])
                    self.send_json(422, {"error": result})
                    return
            else:
                result = "(no hash in bundle)"

            # Write persistent marker so iot-update.service survives a reboot
            BUNDLE_READY_PATH.write_text(json.dumps({
                "version": version_info.get("version", "unknown"),
                "bundle_path": str(BUNDLE_PATH),
                "queued_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }))
            maybe_capture_manifest_url(version_info)
            set_state(
                stage="idle",
                progress_pct=100,
                message=f"Bundle ready: v{version_info.get('version', '?')}. Review and confirm to apply.",
                version_info=version_info,
                error=None,
            )
            audit("/upload", "complete", f"version={version_info.get('version','?')}")

        self.send_json(200, {"chunk": chunk_index, "progress": progress})

    def _handle_apply(self):
        if not _check_rate_limit("/upload/apply", 5, 60):
            audit("rate_limited", "/upload/apply")
            self.send_json(429, {"error": "Rate limit exceeded. Try again later."})
            return
        state = get_state()
        if state["stage"] != "idle" or state.get("version_info") is None:
            self.send_json(409, {"error": "No ready bundle to apply."})
            return
        version_info = state["version_info"]
        threading.Thread(target=trigger_apply, args=(version_info,), daemon=True).start()
        audit("/upload/apply", "ok", f"version={version_info.get('version','?')}")
        self.send_json(200, {"ok": True, "version": version_info.get("version")})

    def _handle_rollback(self):
        """Queue a bootc rollback and reboot."""
        if not _check_rate_limit("/rollback", 3, 60):
            audit("rate_limited", "/rollback")
            self.send_json(429, {"error": "Rate limit exceeded. Try again later."})
            return
        state = get_state()
        if state["stage"] not in ("idle", "error"):
            audit("/rollback", "rejected", f"stage={state['stage']}")
            self.send_json(409, {"error": f"Cannot rollback while in state: {state['stage']}"})
            return

        bs = get_bootc_status(force=True)
        if not bs.get("rollback"):
            audit("/rollback", "rejected", "no rollback deployment available")
            self.send_json(409, {"error": "No rollback deployment available."})
            return

        rollback_image = bs["rollback"].get("image", "previous image")
        threading.Thread(target=do_rollback, daemon=True).start()
        audit("/rollback", "ok", f"to={rollback_image[:80]}")
        self.send_json(200, {"ok": True, "rolling_back_to": rollback_image})

    def _handle_fetch_url(self):
        if not _check_rate_limit("/fetch-url", 5, 60):
            audit("rate_limited", "/fetch-url")
            self.send_json(429, {"error": "Rate limit exceeded. Try again later."})
            return
        state = get_state()
        if state["stage"] not in ("idle", "error"):
            self.send_json(409, {"error": f"Cannot fetch URL in state: {state['stage']}"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length <= 0:
            self.send_json(400, {"error": "Empty request body."})
            return
        body = self.rfile.read(content_length)
        try:
            payload = json.loads(body)
        except Exception:
            self.send_json(400, {"error": "Invalid JSON body."})
            return

        url = payload.get("url", "").strip()
        if not url:
            self.send_json(400, {"error": "Missing 'url' field."})
            return
        if not (url.startswith("https://") or url.startswith("http://")):
            self.send_json(400, {"error": "URL must start with http:// or https://"})
            return
        if not url.endswith(".iotupdate"):
            self.send_json(400, {"error": "URL must point to a .iotupdate file."})
            return

        # Disk space pre-flight (same guard as upload)
        free = shutil.disk_usage("/var/tmp").free
        if free < REQUIRED_DISK_BYTES:
            free_gb = round(free / 1024 ** 3, 1)
            req_gb = round(REQUIRED_DISK_BYTES / 1024 ** 3, 1)
            self.send_json(507, {"error": f"Insufficient disk space: {free_gb} GB free, {req_gb} GB required"})
            return

        BUNDLE_PATH.unlink(missing_ok=True)
        BUNDLE_READY_PATH.unlink(missing_ok=True)
        STATUS_PATH.unlink(missing_ok=True)
        set_state(stage="uploading", progress_pct=0,
                  message=f"Fetching bundle from URL…", version_info=None, error=None)

        # Respond immediately — download happens in background thread
        audit("/fetch-url", "started", url[:120])
        self.send_json(200, {"ok": True, "url": url})

        threading.Thread(target=self._do_fetch_url, args=(url,), daemon=True).start()

    def _do_fetch_url(self, url: str):
        """Download bundle from URL in background, updating progress state."""
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "cockpit-iot-updater/1.0"})
            with urllib.request.urlopen(req, timeout=300) as resp:
                total = int(resp.headers.get("Content-Length") or 0)
                downloaded = 0
                with open(BUNDLE_PATH, "wb") as f:
                    os.chmod(BUNDLE_PATH, 0o600)
                    while True:
                        chunk = resp.read(FETCH_CHUNK_SIZE)
                        if not chunk:
                            break
                        f.write(chunk)
                        downloaded += len(chunk)
                        if total > 0:
                            pct = min(int(downloaded / total * 95), 95)
                            mb = downloaded / 1024 / 1024
                            set_state(stage="uploading", progress_pct=pct,
                                      message=f"Fetching… {mb:.1f} MB downloaded")
        except urllib.error.URLError as e:
            err = f"Fetch failed: {e.reason}"
            BUNDLE_PATH.unlink(missing_ok=True)
            audit("/fetch-url", "error", err[:120])
            set_state(stage="error", message=err, error=err)
            return
        except Exception as e:
            err = f"Fetch error: {e}"
            BUNDLE_PATH.unlink(missing_ok=True)
            audit("/fetch-url", "error", err[:120])
            set_state(stage="error", message=err, error=err)
            return

        # Metadata extraction + verification (same as upload path)
        set_state(stage="extracting", progress_pct=100, message="Reading bundle metadata…")
        version_info = extract_version_from_bundle(BUNDLE_PATH)
        if not version_info or "error" in version_info:
            err = (version_info or {}).get("error", "version.json missing or invalid")
            BUNDLE_PATH.unlink(missing_ok=True)
            set_state(stage="error", message=f"Bundle error: {err}", error=err)
            return

        if version_info.get("image_sha256"):
            set_state(stage="verifying", progress_pct=100,
                      message="Verifying bundle integrity (sha256)…")
            ok, result = verify_bundle_hash(BUNDLE_PATH, version_info)
            if not ok:
                BUNDLE_PATH.unlink(missing_ok=True)
                set_state(stage="error", message=result, error=result)
                return

        BUNDLE_READY_PATH.write_text(json.dumps({
            "version": version_info.get("version", "unknown"),
            "bundle_path": str(BUNDLE_PATH),
            "queued_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }))
        maybe_capture_manifest_url(version_info)
        audit("/fetch-url", "complete", f"version={version_info.get('version','?')}")
        set_state(
            stage="idle", progress_pct=100,
            message=f"Bundle ready: v{version_info.get('version', '?')}. Review and confirm to apply.",
            version_info=version_info, error=None,
        )


def main():
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    rotate_log()
    server = http.server.ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), UpdateHandler)
    print(f"[iot-updater] Listening on {LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
