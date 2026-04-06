/* update.js — Cockpit IoT Updater page logic
 *
 * All sidecar calls go through cockpit.http() which routes via the Cockpit
 * bridge WebSocket — already TLS-encrypted by Cockpit (port 9090).
 * The sidecar binds to 127.0.0.1:8088 and is never exposed directly.
 */

const CHUNK_SIZE = 8 * 1024 * 1024; // 8 MB per chunk

const api       = cockpit.http(8088);
const uploadApi = cockpit.http(8088, { binary: true });

let selectedFile     = null;
let versionPreview   = null;
let currentVersion   = null;
let statusPoller     = null;
let bootcPoller      = null;
let sidecarOk        = false;

// ── Boot ─────────────────────────────────────────────────────────────────────
document.addEventListener("DOMContentLoaded", function() {
    pollStatus();
    pollBootcStatus();
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
    document.getElementById("btn-rollback").addEventListener("click", doRollback);
    document.getElementById("allow-downgrade").addEventListener("change", function() {
        var applyBtn = document.getElementById("btn-apply");
        if (versionPreview) {
            applyBtn.disabled = isDowngrade() && !this.checked;
        }
    });

    document.getElementById("log-toggle").addEventListener("click", function() {
        logOpen = !logOpen;
        var out = document.getElementById("log-output");
        this.textContent = (logOpen ? "▼ Hide" : "▶ Show") + " log output";
        out.classList.toggle("open", logOpen);
        if (logOpen) loadLog(200);
    });
    document.getElementById("log-refresh").addEventListener("click", function() {
        if (logOpen) loadLog(200);
    });

    // Initial log load to show/hide the card based on /logs availability
    loadLog();
});

// ── Status polling (sidecar state machine) ────────────────────────────────────
function pollStatus() {
    api.get("/status")
        .then(function(text) {
            var s = JSON.parse(text);
            sidecarOk = true;
            document.getElementById("sidecar-warn").style.display = "none";
            renderStatus(s);
            if (s.stage === "idle" && s.message && s.message.indexOf("applied") !== -1) {
                loadHistory();
                pollBootcStatus(true);
                loadLog(200);
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

    var activeStages = ["uploading", "extracting", "verifying", "queued", "applying", "rebooting"];
    var isActive = activeStages.indexOf(s.stage) !== -1;
    var progressArea = document.getElementById("progress-area");
    progressArea.style.display = isActive ? "block" : "none";
    if (isActive) {
        document.getElementById("progress-fill").style.width = s.progress_pct + "%";
        document.getElementById("progress-label").textContent = s.message || (s.progress_pct + "%");
    }

    var errEl = document.getElementById("error-msg");
    errEl.style.display = s.stage === "error" ? "block" : "none";
    if (s.stage === "error") errEl.textContent = s.message || "An error occurred.";

    var applyBtn  = document.getElementById("btn-apply");
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
        // If there's a ready bundle (version_info set before apply was triggered),
        // allow retry. Otherwise reset the UI so the user can drop a new file.
        if (versionPreview) {
            applyBtn.style.display = "";
            applyBtn.disabled = false;
            applyBtn.textContent = "Retry Apply v" + versionPreview.version;
        } else {
            applyBtn.style.display = "none";
            // Reset drop zone so user can select a new file without reloading
            document.getElementById("dz-title").textContent = "Drop .iotupdate file here";
            document.getElementById("dz-sub").textContent   = "or click to browse";
            document.getElementById("file-input").value     = "";
            selectedFile = null;
        }
        cancelBtn.style.display = "none";
    } else if (s.stage === "rebooting") {
        applyBtn.style.display = "none";
        cancelBtn.style.display = "none";
    }
}

function stageLabel(stage) {
    var labels = {
        idle:      "Idle",
        uploading: "Uploading…",
        extracting:"Extracting…",
        verifying: "Verifying integrity…",
        queued:    "Queued",
        applying:  "Applying…",
        rebooting: "Rebooting…",
        error:     "Error"
    };
    return labels[stage] || stage;
}

function setBadge(stage, label) {
    var b = document.getElementById("status-badge");
    b.textContent = label;
    var cls = "idle";
    if (["uploading", "extracting"].indexOf(stage) !== -1) cls = "uploading";
    else if (stage === "verifying") cls = "verifying";
    else if (["queued", "applying"].indexOf(stage) !== -1) cls = "applying";
    else if (stage === "rebooting") cls = "rebooting";
    else if (stage === "error")     cls = "error";
    b.className = "badge-" + cls;
}

// ── Bootc status (real deployment info) ───────────────────────────────────────
function pollBootcStatus(force) {
    api.get("/bootc-status")
        .then(function(text) {
            var bs = JSON.parse(text);
            renderBootcStatus(bs);
        })
        .catch(function() {
            document.getElementById("di-image").textContent = "Unavailable (sidecar unreachable)";
        })
        .always(function() {
            // Poll every 10s — bootc status is cached 5s on sidecar
            bootcPoller = setTimeout(pollBootcStatus, 10000);
        });
}

function renderBootcStatus(bs) {
    var booted = bs.booted || {};
    document.getElementById("di-image").textContent     = booted.image     || "—";
    document.getElementById("di-version").textContent   = booted.version   || "—";
    document.getElementById("di-timestamp").textContent = booted.timestamp ? formatTs(booted.timestamp) : "—";
    document.getElementById("di-digest").textContent    = truncHash(booted.digest);
    document.getElementById("di-digest").title          = booted.digest || "";

    // Current version for downgrade detection
    if (booted.image) {
        var m = booted.image.match(/:(.+)$/);
        if (m) currentVersion = m[1];
    }

    // Staged banner
    var stagedBanner = document.getElementById("staged-banner");
    if (bs.staged) {
        document.getElementById("staged-image").textContent = bs.staged.image || "unknown";
        stagedBanner.style.display = "block";
    } else {
        stagedBanner.style.display = "none";
    }

    // Rollback section
    var rbSection = document.getElementById("rollback-section");
    if (bs.rollback) {
        document.getElementById("rb-image").textContent   = bs.rollback.image   || "—";
        document.getElementById("rb-version").textContent = bs.rollback.version || "—";
        document.getElementById("rb-digest").textContent  = truncHash(bs.rollback.digest);
        document.getElementById("rb-digest").title        = bs.rollback.digest  || "";
        rbSection.style.display = "block";
    } else {
        rbSection.style.display = "none";
    }
}

function truncHash(hash) {
    if (!hash) return "—";
    // Remove "sha256:" prefix, show first 16 hex chars + "…"
    var h = hash.replace(/^sha256:/, "");
    return h.length > 16 ? h.substring(0, 16) + "…" : h;
}

function formatTs(ts) {
    // ts is ISO 8601 — format as local date+time
    try {
        return new Date(ts).toLocaleString();
    } catch(e) {
        return ts;
    }
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

    api.request({ method: "POST", path: "/upload/start", body: "" })
        .then(function() {
            document.getElementById("progress-area").style.display = "block";
            return sendChunks(file, totalChunks, 0);
        })
        .then(function() {
            return api.get("/status");
        })
        .then(function(text) {
            var s = JSON.parse(text);
            document.getElementById("progress-area").style.display = "none";
            if (s.stage === "error") {
                showError(s.error || s.message || "Bundle verification failed.");
                return;
            }
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
                // Show verifying state on last chunk (server streams hash check)
                if (index + 1 >= totalChunks) {
                    updateProgress(99, "Verifying bundle integrity…");
                } else {
                    updateProgress(pct, "Uploading… " + pct + "%");
                }
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
    document.getElementById("pv-version").textContent = info.version    || "—";
    document.getElementById("pv-date").textContent    = info.build_date || "—";
    document.getElementById("pv-desc").textContent    = info.description || "—";
    document.getElementById("pv-type").textContent    = info.dry_run
        ? "🧪 Dry run (no actual update)" : "Production";

    // SHA256 display
    if (info.image_sha256) {
        var hashRow = document.getElementById("pv-hash-row");
        var hashEl  = document.getElementById("pv-hash");
        hashEl.textContent = info.image_sha256.substring(0, 16) + "…";
        hashEl.title       = info.image_sha256;
        hashRow.style.display = "";
    }

    document.getElementById("version-preview").style.display = "block";
    document.getElementById("downgrade-warning").style.display = isDowngrade() ? "block" : "none";

    var applyBtn = document.getElementById("btn-apply");
    applyBtn.textContent = "Apply v" + info.version;
    applyBtn.disabled    = isDowngrade() && !document.getElementById("allow-downgrade").checked;

    document.getElementById("dz-sub").textContent =
        (selectedFile.size / 1024 / 1024).toFixed(1) + " MB — ready to apply";
}

function isDowngrade() {
    if (!currentVersion || !versionPreview || !versionPreview.version) return false;
    return versionCompare(versionPreview.version, currentVersion) <= 0;
}

function versionCompare(a, b) {
    // Handle "v9" style tags by stripping leading "v"
    var norm = function(s) { return s.replace(/^v/, "").split(".").map(Number); };
    var pa = norm(a), pb = norm(b);
    for (var i = 0; i < Math.max(pa.length, pb.length); i++) {
        var diff = (pa[i] || 0) - (pb[i] || 0);
        if (diff !== 0) return diff;
    }
    return 0;
}

// ── Apply / Cancel ────────────────────────────────────────────────────────────
function applyUpdate() {
    if (!versionPreview) return;
    var msg = "Apply update " + versionPreview.version + "?";
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
            selectedFile   = null;
            document.getElementById("version-preview").style.display  = "none";
            document.getElementById("downgrade-warning").style.display = "none";
            document.getElementById("pv-hash-row").style.display       = "none";
            document.getElementById("dz-title").textContent = "Drop .iotupdate file here";
            document.getElementById("dz-sub").textContent   = "or click to browse";
            document.getElementById("btn-apply").disabled   = true;
            document.getElementById("btn-apply").textContent = "Apply Update";
            document.getElementById("btn-cancel").style.display = "none";
            document.getElementById("file-input").value = "";
        })
        .catch(function(err) {
            showError("Cancel failed: " + (err.message || String(err)));
        });
}

// ── Rollback ──────────────────────────────────────────────────────────────────
function doRollback() {
    var rbImage = document.getElementById("rb-image").textContent || "previous image";
    if (!confirm("Roll back to " + rbImage + "?\n\nThe device will reboot immediately.")) return;

    var btn = document.getElementById("btn-rollback");
    btn.disabled = true;
    btn.textContent = "Rolling back…";

    api.request({ method: "POST", path: "/rollback", body: "" })
        .then(function(text) {
            var r = JSON.parse(text);
            setBadge("rebooting", "Rolling back…");
            // Page will become unreachable on reboot — show message
            document.getElementById("error-msg").style.color = "#1e7e34";
            showError("Rollback triggered. Device is rebooting to " + (r.rolling_back_to || rbImage) + ".\nReconnect in ~60 seconds.");
        })
        .catch(function(err) {
            btn.disabled = false;
            btn.textContent = "⏎ Rollback and Reboot";
            showError("Rollback failed: " + (err.message || err.problem || String(err)));
        });
}

// ── History ───────────────────────────────────────────────────────────────────
function loadHistory() {
    api.get("/history")
        .then(function(text) {
            var history = JSON.parse(text);
            renderHistory(history);
        })
        .catch(function() {
            document.getElementById("history-loading").style.display = "none";
            document.getElementById("history-empty").style.display   = "block";
            document.getElementById("history-empty").textContent = "Could not load history.";
        });
}

function renderHistory(history) {
    document.getElementById("history-loading").style.display = "none";
    var tbl   = document.getElementById("history-table");
    var empty = document.getElementById("history-empty");

    if (!history || history.length === 0) {
        tbl.style.display   = "none";
        empty.style.display = "block";
        return;
    }
    tbl.style.display   = "table";
    empty.style.display = "none";

    var rows = [];
    var rev  = history.slice().reverse();
    for (var i = 0; i < rev.length; i++) {
        var h = rev[i];
        var pillClass = "pill-" + (h.status || "applying").replace(/[^a-z_]/g, "");
        var sha = h.sha256 ? ('<span class="hash-display" title="' + esc(h.sha256) + '">' + h.sha256.substring(0,16) + "…</span>") : "";
        var snippetHtml = "";
        if (h.status === "error" && h.log_snippet && h.log_snippet.length) {
            var snippetId = "snippet-" + i;
            var snippetLines = h.log_snippet.map(function(l) { return esc(l); }).join("\n");
            snippetHtml = '<br><button class="snippet-toggle" onclick="toggleSnippet(\'' + snippetId + '\')">▶ Show log</button>' +
                          '<div class="log-snippet" id="' + snippetId + '">' + snippetLines + '</div>';
        }
        rows.push(
            "<tr>" +
            "<td><strong>" + esc(h.version) + "</strong>" + (sha ? "<br><small>sha256: " + sha + "</small>" : "") + "</td>" +
            "<td>" + esc(h.applied_at_complete || h.applied_at || "—") + "</td>" +
            "<td>" + esc(h.description || "—") + snippetHtml + "</td>" +
            "<td><span class='status-pill " + pillClass + "'>" + esc(h.status) + "</span></td>" +
            "</tr>"
        );
    }
    document.getElementById("history-body").innerHTML = rows.join("");
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function toggleSnippet(id) {
    var el = document.getElementById(id);
    if (!el) return;
    var open = el.style.display === "block";
    el.style.display = open ? "none" : "block";
    var btn = el.previousElementSibling;
    if (btn) btn.textContent = (open ? "▶" : "▼") + " Show log";
}

// ── Update Log viewer ─────────────────────────────────────────────────────────
var logOpen = false;

function loadLog(lines) {
    lines = lines || 100;
    api.get("/logs?lines=" + lines)
        .then(function(text) {
            var data = JSON.parse(text);
            var logLines = data.lines || [];
            renderLog(logLines);
            document.getElementById("log-card").classList.add("visible");
        })
        .catch(function() {
            // /logs not available — hide log card
            document.getElementById("log-card").classList.remove("visible");
        });
}

function renderLog(lines) {
    var out = document.getElementById("log-output");
    if (!lines.length) {
        out.textContent = "(no log entries yet)";
        return;
    }
    var html = lines.map(function(line) {
        var cls = "";
        if (line.indexOf("[ERROR]") !== -1)   cls = "log-line-error";
        if (line.indexOf("[SUCCESS]") !== -1 || line.indexOf("[COMPLETE]") !== -1) cls = "log-line-success";
        return '<span class="' + cls + '">' + esc(line) + '</span>';
    }).join("\n");
    out.innerHTML = html;
    out.scrollTop = out.scrollHeight;
}

function updateProgress(pct, label) {
    document.getElementById("progress-fill").style.width = pct + "%";
    document.getElementById("progress-label").textContent = label;
}

function showError(msg) {
    var el = document.getElementById("error-msg");
    el.textContent  = msg;
    el.style.display = "block";
}

function clearError() {
    var el = document.getElementById("error-msg");
    el.style.display = "none";
    el.style.color   = "#c9190b";
}

function esc(s) {
    return String(s || "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}
