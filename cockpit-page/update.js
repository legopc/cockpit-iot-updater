/* update.js — Cockpit IoT Updater page logic
 *
 * All sidecar calls go through cockpit.http() which routes via the Cockpit
 * bridge WebSocket, bypassing browser CSP and mixed-content restrictions.
 */

const CHUNK_SIZE = 8 * 1024 * 1024; // 8 MB per chunk

// Two clients: text mode for JSON API, binary mode for upload chunks
const api = cockpit.http(8088);
const uploadApi = cockpit.http(8088, { binary: true });

let selectedFile = null;
let versionPreview = null;
let currentVersion = null;
let statusPoller = null;
let sidecarOk = false;

// ── Boot ─────────────────────────────────────────────────────────────────────
document.addEventListener("DOMContentLoaded", () => {
    pollStatus();
    loadHistory();

    setupDropZone();
    document.getElementById("file-input").addEventListener("change", function(e) {
        if (e.target.files[0]) handleFileSelected(e.target.files[0]);
    });
    document.getElementById("drop-zone").addEventListener("click", function() {
        document.getElementById("file-input").click();
    });
    document.getElementById("btn-apply").addEventListener("click", applyUpdate);
    document.getElementById("btn-cancel").addEventListener("click", cancelUpload);
    document.getElementById("allow-downgrade").addEventListener("change", function() {
        var applyBtn = document.getElementById("btn-apply");
        if (versionPreview) {
            applyBtn.disabled = isDowngrade() && !this.checked;
        }
    });
});

// ── Status polling ────────────────────────────────────────────────────────────
function pollStatus() {
    api.get("/status")
        .then(function(text) {
            var s = JSON.parse(text);
            sidecarOk = true;
            document.getElementById("sidecar-warn").style.display = "none";
            renderStatus(s);
            // Refresh history after a completed apply
            if (s.stage === "idle" && s.message && s.message.indexOf("applied") !== -1) {
                loadHistory();
            }
        })
        .catch(function() {
            sidecarOk = false;
            document.getElementById("sidecar-warn").style.display = "block";
            setBadge("error", "Sidecar unreachable");
        })
        .always(function() {
            statusPoller = setTimeout(pollStatus, 2000);
        });
}

function renderStatus(s) {
    setBadge(s.stage, stageLabel(s.stage));

    var isActive = ["uploading", "extracting", "queued", "applying", "rebooting"].indexOf(s.stage) !== -1;
    var progressArea = document.getElementById("progress-area");
    progressArea.style.display = isActive ? "block" : "none";
    if (isActive) {
        document.getElementById("progress-fill").style.width = s.progress_pct + "%";
        document.getElementById("progress-label").textContent = s.message || (s.progress_pct + "%");
    }

    var errEl = document.getElementById("error-msg");
    errEl.style.display = s.stage === "error" ? "block" : "none";
    if (s.stage === "error") errEl.textContent = s.message || "An error occurred.";

    var applyBtn = document.getElementById("btn-apply");
    var cancelBtn = document.getElementById("btn-cancel");

    if (s.stage === "idle") {
        applyBtn.style.display = "";
        applyBtn.disabled = !versionPreview || (isDowngrade() && !document.getElementById("allow-downgrade").checked);
        if (versionPreview) applyBtn.textContent = "Apply v" + versionPreview.version;
        cancelBtn.style.display = "none";
    } else if (isActive) {
        applyBtn.style.display = "none";
        cancelBtn.style.display = s.stage === "uploading" ? "" : "none";
    } else if (s.stage === "error") {
        applyBtn.style.display = "";
        applyBtn.disabled = false;
        applyBtn.textContent = "Retry Upload";
        cancelBtn.style.display = "";
    } else if (s.stage === "rebooting") {
        applyBtn.style.display = "none";
        cancelBtn.style.display = "none";
    }
}

function stageLabel(stage) {
    var labels = {
        idle: "Idle", uploading: "Uploading…", extracting: "Extracting…",
        queued: "Queued", applying: "Applying…", rebooting: "Rebooting…", error: "Error"
    };
    return labels[stage] || stage;
}

function setBadge(stage, label) {
    var b = document.getElementById("status-badge");
    b.textContent = label;
    var cls = "idle";
    if (["uploading", "extracting", "queued"].indexOf(stage) !== -1) cls = "uploading";
    else if (stage === "applying") cls = "applying";
    else if (stage === "rebooting") cls = "rebooting";
    else if (stage === "error") cls = "error";
    b.className = "badge-" + cls;
}

// ── Drop zone ─────────────────────────────────────────────────────────────────
function setupDropZone() {
    var zone = document.getElementById("drop-zone");
    zone.addEventListener("dragover", function(e) {
        e.preventDefault();
        zone.classList.add("dragover");
    });
    zone.addEventListener("dragleave", function() {
        zone.classList.remove("dragover");
    });
    zone.addEventListener("drop", function(e) {
        e.preventDefault();
        zone.classList.remove("dragover");
        var f = e.dataTransfer.files[0];
        if (f) handleFileSelected(f);
    });
}

function handleFileSelected(file) {
    if (file.name.indexOf(".iotupdate") === -1) {
        showError("Please select a .iotupdate file.");
        return;
    }
    selectedFile = file;
    clearError();
    document.getElementById("dz-title").textContent = file.name;
    document.getElementById("dz-sub").textContent =
        (file.size / 1024 / 1024).toFixed(1) + " MB — uploading…";
    uploadAndPreview(file);
}

// ── Chunked upload via cockpit.http() ─────────────────────────────────────────
function uploadAndPreview(file) {
    var totalChunks = Math.ceil(file.size / CHUNK_SIZE);

    // Start upload session
    api.request({ method: "POST", path: "/upload/start", body: "" })
        .then(function() {
            document.getElementById("progress-area").style.display = "block";
            return sendChunks(file, totalChunks, 0);
        })
        .then(function() {
            // Fetch version preview from the status
            return api.get("/status");
        })
        .then(function(text) {
            var s = JSON.parse(text);
            document.getElementById("progress-area").style.display = "none";
            if (s.version_info) {
                versionPreview = s.version_info;
                showVersionPreview(versionPreview);
            } else {
                showError("Upload complete but version info missing from bundle.");
            }
        })
        .catch(function(err) {
            document.getElementById("progress-area").style.display = "none";
            showError("Upload failed: " + (err.message || err.problem || String(err)));
        });
}

function sendChunks(file, totalChunks, index) {
    if (index >= totalChunks) return cockpit.resolve();

    var chunk = file.slice(index * CHUNK_SIZE, (index + 1) * CHUNK_SIZE);

    return new Promise(function(resolve, reject) {
        var reader = new FileReader();
        reader.onload = function(e) {
            var buffer = new Uint8Array(e.target.result);
            uploadApi.request({
                method: "POST",
                path: "/upload",
                headers: {
                    "Content-Type": "application/octet-stream",
                    "X-Chunk-Index": String(index),
                    "X-Total-Chunks": String(totalChunks)
                },
                body: buffer
            })
            .then(function(respBytes) {
                var text = new TextDecoder().decode(respBytes);
                var j = JSON.parse(text);
                var pct = Math.round(((index + 1) / totalChunks) * 100);
                updateProgress(pct, "Uploading… " + pct + "%");
                resolve();
            })
            .catch(reject);
        };
        reader.onerror = function() { reject(new Error("File read error")); };
        reader.readAsArrayBuffer(chunk);
    }).then(function() {
        return sendChunks(file, totalChunks, index + 1);
    });
}

function showVersionPreview(info) {
    document.getElementById("pv-version").textContent = info.version || "—";
    document.getElementById("pv-date").textContent = info.build_date || "—";
    document.getElementById("pv-desc").textContent = info.description || "—";
    document.getElementById("pv-type").textContent = info.dry_run ? "🧪 Dry run (no actual update)" : "Production";
    document.getElementById("version-preview").style.display = "block";

    if (isDowngrade()) {
        document.getElementById("downgrade-warning").style.display = "block";
    } else {
        document.getElementById("downgrade-warning").style.display = "none";
    }

    var applyBtn = document.getElementById("btn-apply");
    applyBtn.textContent = "Apply v" + info.version;
    applyBtn.disabled = isDowngrade() && !document.getElementById("allow-downgrade").checked;

    document.getElementById("dz-sub").textContent =
        (selectedFile.size / 1024 / 1024).toFixed(1) + " MB — ready to apply";
}

function isDowngrade() {
    if (!currentVersion || !versionPreview || !versionPreview.version) return false;
    return versionCompare(versionPreview.version, currentVersion) <= 0;
}

function versionCompare(a, b) {
    var pa = a.split(".").map(Number);
    var pb = b.split(".").map(Number);
    for (var i = 0; i < Math.max(pa.length, pb.length); i++) {
        var diff = (pa[i] || 0) - (pb[i] || 0);
        if (diff !== 0) return diff;
    }
    return 0;
}

// ── Apply / Cancel ────────────────────────────────────────────────────────────
function applyUpdate() {
    if (!versionPreview) return;
    var msg = "Apply update v" + versionPreview.version + "?";
    if (!versionPreview.dry_run) msg += "\n\nThe device will reboot after the update is applied.";
    if (!confirm(msg)) return;

    api.request({ method: "POST", path: "/upload/apply", body: "" })
        .catch(function(err) {
            showError("Failed to trigger update: " + (err.message || err.problem || String(err)));
        });
}

function cancelUpload() {
    api.request({ method: "POST", path: "/upload/cancel", body: "" })
        .then(function() {
            versionPreview = null;
            selectedFile = null;
            document.getElementById("version-preview").style.display = "none";
            document.getElementById("downgrade-warning").style.display = "none";
            document.getElementById("dz-title").textContent = "Drop .iotupdate file here";
            document.getElementById("dz-sub").textContent = "or click to browse";
            document.getElementById("btn-apply").disabled = true;
            document.getElementById("btn-apply").textContent = "Apply Update";
            document.getElementById("btn-cancel").style.display = "none";
            document.getElementById("file-input").value = "";
        })
        .catch(function(err) {
            showError("Cancel failed: " + (err.message || String(err)));
        });
}

// ── History ───────────────────────────────────────────────────────────────────
function loadHistory() {
    api.get("/history")
        .then(function(text) {
            var history = JSON.parse(text);
            renderHistory(history);

            // Update current version from history
            var applied = history.filter(function(h) { return h.status === "applied" || h.status === "dry_run"; });
            if (applied.length > 0) {
                var last = applied[applied.length - 1];
                currentVersion = last.version;
                renderCurrentDeployment(last);
            } else {
                document.getElementById("current-info").textContent = "No updates applied via this tool yet.";
            }
        })
        .catch(function() {
            document.getElementById("history-loading").style.display = "none";
            document.getElementById("history-empty").style.display = "block";
            document.getElementById("history-empty").textContent = "Could not load history (sidecar unreachable).";
            document.getElementById("current-info").textContent = "Sidecar unreachable.";
        });
}

function renderCurrentDeployment(last) {
    var el = document.getElementById("current-info");
    el.innerHTML =
        '<table style="border-collapse:collapse;font-size:0.9rem">' +
        '<tr><td style="padding:3px 8px;color:#6a6e73;font-weight:600">Version</td>' +
        '<td style="padding:3px 8px">' + esc(last.version) + '</td></tr>' +
        '<tr><td style="padding:3px 8px;color:#6a6e73;font-weight:600">Applied</td>' +
        '<td style="padding:3px 8px">' + esc(last.applied_at_complete || last.applied_at || "—") + '</td></tr>' +
        '</table>';
}

function renderHistory(history) {
    document.getElementById("history-loading").style.display = "none";
    var tbl = document.getElementById("history-table");
    var empty = document.getElementById("history-empty");

    if (!history || history.length === 0) {
        tbl.style.display = "none";
        empty.style.display = "block";
        return;
    }
    tbl.style.display = "table";
    empty.style.display = "none";

    var rows = [];
    var rev = history.slice().reverse();
    for (var i = 0; i < rev.length; i++) {
        var h = rev[i];
        var pillClass = "pill-" + (h.status || "applying").replace(/[^a-z_]/g, "");
        rows.push(
            "<tr>" +
            "<td><strong>" + esc(h.version) + "</strong></td>" +
            "<td>" + esc(h.applied_at_complete || h.applied_at || "—") + "</td>" +
            "<td>" + esc(h.description || "—") + "</td>" +
            "<td><span class='status-pill " + pillClass + "'>" + esc(h.status) + "</span></td>" +
            "</tr>"
        );
    }
    document.getElementById("history-body").innerHTML = rows.join("");
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function updateProgress(pct, label) {
    document.getElementById("progress-fill").style.width = pct + "%";
    document.getElementById("progress-label").textContent = label;
}

function showError(msg) {
    var el = document.getElementById("error-msg");
    el.textContent = msg;
    el.style.display = "block";
}

function clearError() {
    document.getElementById("error-msg").style.display = "none";
}

function esc(s) {
    return String(s || "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}
