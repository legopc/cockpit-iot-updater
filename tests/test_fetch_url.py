import importlib.util
import json
import threading
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "sidecar" / "server.py"


def load_server(tmp_path):
    spec = importlib.util.spec_from_file_location("iot_server_under_test", SERVER_PATH)
    server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server)

    server.BUNDLE_PATH = tmp_path / "iot43-update.iotupdate"
    server.BUNDLE_PART_PATH = Path(str(server.BUNDLE_PATH) + ".part")
    server.BUNDLE_READY_PATH = tmp_path / "bundle-ready"
    server.STATUS_PATH = tmp_path / "status.json"
    server.AUDIT_LOG_PATH = tmp_path / "audit.log"
    server.MANIFEST_CONFIG_PATH = tmp_path / "manifest.json"
    server._state.update({
        "stage": "idle",
        "progress_pct": 0,
        "message": "Ready for upload.",
        "version_info": None,
        "error": None,
    })
    return server


class BlockingResponse:
    def __init__(self):
        self.headers = {"Content-Length": "10"}
        self.first_read_done = threading.Event()
        self.finish = threading.Event()
        self.reads = 0

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self, _size):
        self.reads += 1
        if self.reads == 1:
            self.first_read_done.set()
            return b"12345"
        if self.reads == 2:
            self.finish.wait(timeout=5)
            return b"67890"
        return b""


def test_cancel_during_fetch_does_not_report_missing_bundle_or_resurrect_file(tmp_path, monkeypatch):
    server = load_server(tmp_path)
    response = BlockingResponse()
    monkeypatch.setattr(server.urllib.request, "urlopen", lambda req, timeout: response)
    monkeypatch.setattr(server, "extract_version_from_bundle", lambda path: {"version": "v99"})
    monkeypatch.setattr(server, "verify_bundle_hash", lambda path, info: (True, "ok"))

    fetch_thread = threading.Thread(target=server.UpdateHandler._do_fetch_url, args=(object(), "http://example/update.iotupdate"))
    fetch_thread.start()

    assert response.first_read_done.wait(timeout=5)
    server.cancel_active_transfer("Upload cancelled.")
    response.finish.set()
    fetch_thread.join(timeout=5)

    assert not fetch_thread.is_alive()
    assert not server.BUNDLE_PATH.exists()
    assert not server.BUNDLE_PART_PATH.exists()
    assert not server.BUNDLE_READY_PATH.exists()
    state = server.get_state()
    assert state["stage"] == "idle"
    assert state["version_info"] is None
    assert "No such file or directory" not in json.dumps(state)


class ErrorAfterCancelResponse:
    headers = {"Content-Length": "10"}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self, _size):
        raise OSError("late socket failure")


def test_cancelled_fetch_late_exception_does_not_overwrite_cancel_state(tmp_path, monkeypatch):
    server = load_server(tmp_path)
    server.set_state(stage="idle", progress_pct=0, message="Upload cancelled.", version_info=None, error=None)
    transfer_id = server.start_transfer() - 1
    monkeypatch.setattr(server.urllib.request, "urlopen", lambda req, timeout: ErrorAfterCancelResponse())

    server.UpdateHandler._do_fetch_url(object(), "http://example/update.iotupdate", transfer_id)

    state = server.get_state()
    assert state["stage"] == "idle"
    assert state["message"] == "Upload cancelled."
    assert state["error"] is None


def test_cancel_during_metadata_does_not_finalize_ready_bundle(tmp_path, monkeypatch):
    server = load_server(tmp_path)
    response = BlockingResponse()
    response.finish.set()
    metadata_started = threading.Event()
    release_metadata = threading.Event()

    def extract_after_cancel(path):
        metadata_started.set()
        release_metadata.wait(timeout=5)
        return {"version": "v99"}

    monkeypatch.setattr(server.urllib.request, "urlopen", lambda req, timeout: response)
    monkeypatch.setattr(server, "extract_version_from_bundle", extract_after_cancel)
    monkeypatch.setattr(server, "verify_bundle_hash", lambda path, info: (True, "ok"))

    transfer_id = server.start_transfer()
    fetch_thread = threading.Thread(target=server.UpdateHandler._do_fetch_url, args=(object(), "http://example/update.iotupdate", transfer_id))
    fetch_thread.start()

    assert metadata_started.wait(timeout=5)
    server.cancel_active_transfer("Upload cancelled.")
    release_metadata.set()
    fetch_thread.join(timeout=5)

    assert not fetch_thread.is_alive()
    assert not server.BUNDLE_PATH.exists()
    assert not server.BUNDLE_READY_PATH.exists()
    state = server.get_state()
    assert state["stage"] == "idle"
    assert state["version_info"] is None
