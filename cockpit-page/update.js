/* update.js — Cockpit IoT Updater page logic
 *
 * All sidecar calls go through cockpit.http() which routes via the Cockpit
 * bridge WebSocket — already TLS-encrypted by Cockpit (port 9090).
 * The sidecar binds to 127.0.0.1:8088 and is never exposed directly.
 */

const CHUNK_SIZE = 8 * 1024 * 1024; // 8 MB per chunk

const api       = cockpit.http(8088);
const uploadApi = cockpit.http(8088, { binary: true });

var state = {
    selectedFile:   null,
    versionPreview: null,
    currentVersion: null,
    statusPoller:   null,
    bootcPoller:    null,
    sidecarOk:      false,
    uploadStartTime: null,
    uploadedBytes:   0,
};

function resetState() {
    state.selectedFile   = null;
    state.versionPreview = null;
    // Note: currentVersion, pollers, sidecarOk are not reset — they reflect live device state
}

// ── Toast notifications ───────────────────────────────────────────────────────
function showToast(type, msg, autoDismiss) {
    var icons = { success: "✓", error: "✕", info: "ℹ" };
    var area = document.getElementById("toast-area");
    var toast = document.createElement("div");
    toast.className = "toast toast-" + type;
    toast.innerHTML =
        '<span class="toast-icon">' + (icons[type] || "ℹ") + '</span>' +
        '<span style="flex:1">' + esc(msg) + '</span>' +
        '<span class="toast-close" onclick="this.parentElement.remove()">×</span>';
    area.appendChild(toast);
    if (autoDismiss !== false) {
        setTimeout(function() { if (toast.parentElement) toast.remove(); }, 6000);
    }
}

var statusFailCount = 0;
var rebootCountdown = null;
var _prevStage = null;

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
        if (state.versionPreview) {
            applyBtn.disabled = isDowngrade() && !this.checked;
        }
    });

    document.getElementById("log-refresh").addEventListener("click", function() {
        loadLog(200);
    });

    // Initial log load to show/hide the card based on /logs availability
    loadLog();

    document.getElementById("btn-fetch-url").addEventListener("click", fetchFromUrl);

    loadDiskSpace();

    window.addEventListener("beforeunload", function() {
        if (state.statusPoller) clearTimeout(state.statusPoller);
        if (state.bootcPoller)  clearTimeout(state.bootcPoller);
        if (rebootCountdown)    clearInterval(rebootCountdown);
        try { api.request({ method: "POST", path: "/upload/cancel", body: "" }); } catch(e) {}
    });
});

// ── Status polling (sidecar state machine) ────────────────────────────────────
function pollStatus() {
    api.get("/status")
        .then(function(text) {
            statusFailCount = 0;
            var s = JSON.parse(text);
            state.sidecarOk = true;
            document.getElementById("sidecar-warn").style.display = "none";
            renderStatus(s);
            if (s.stage === "idle" && s.message && s.message.indexOf("applied") !== -1) {
                loadHistory();
                pollBootcStatus(true);
                loadLog(200);
            }
        })
        .catch(function() {
            statusFailCount++;
            if (statusFailCount >= 5 && rebootCountdown === null) {
                startRebootCountdown();
            } else if (statusFailCount < 5) {
                state.sidecarOk = false;
                document.getElementById("sidecar-warn").style.display = "block";
                setBadge("error", "Sidecar unreachable");
            }
        })
        .always(function() {
            state.statusPoller = setTimeout(pollStatus, 2000);
        });
}

function startRebootCountdown() {
    var secs = 60;
    showToast("info", "⏳ Device is rebooting… reconnecting in " + secs + "s", false);
    var toastEl = document.querySelector("#toast-area .toast:last-child");

    rebootCountdown = setInterval(function() {
        secs--;
        if (toastEl) {
            var msgEl = toastEl.querySelector("span:nth-child(2)");
            if (msgEl) msgEl.textContent = "⏳ Device is rebooting… reconnecting in " + secs + "s";
        }
        if (secs <= 0) {
            clearInterval(rebootCountdown);
            rebootCountdown = null;
            location.reload();
        }
    }, 1000);
}

function renderStatus(s) {
    if (s.stage === "error" && _prevStage !== "error") {
        showToast("error", s.message || "Update failed.");
    }
    if (s.stage === "idle" && s.message && s.message.indexOf("applied") !== -1 && _prevStage === "rebooting") {
        showToast("success", "Update applied successfully!");
    }
    _prevStage = s.stage;

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
    if (errEl) {
        errEl.style.display = s.stage === "error" ? "block" : "none";
        if (s.stage === "error") errEl.textContent = s.message || "An error occurred.";
    }

    var applyBtn  = document.getElementById("btn-apply");
    var cancelBtn = document.getElementById("btn-cancel");

    if (s.stage === "idle") {
        applyBtn.style.display = "";
        applyBtn.disabled = !state.versionPreview || (isDowngrade() && !document.getElementById("allow-downgrade").checked);
        if (state.versionPreview) applyBtn.textContent = state.versionPreview.dry_run ? "Apply v" + stripV(state.versionPreview.version) + " (dry run)" : "Apply & Reboot v" + stripV(state.versionPreview.version);
        cancelBtn.style.display = "none";
    } else if (isActive) {
        applyBtn.style.display = "none";
        cancelBtn.style.display = s.stage === "uploading" ? "" : "none";
    } else if (s.stage === "error") {
        // If there's a ready bundle (version_info set before apply was triggered),
        // allow retry. Otherwise reset the UI so the user can drop a new file.
        if (state.versionPreview) {
            applyBtn.style.display = "";
            applyBtn.disabled = false;
            var isDry = state.versionPreview && state.versionPreview.dry_run;
            applyBtn.textContent = (isDry ? "Retry Apply" : "Retry Apply & Reboot") + " v" + stripV(state.versionPreview.version);
        } else {
            applyBtn.style.display = "none";
            // Reset drop zone so user can select a new file without reloading
            document.getElementById("dz-title").textContent = "Drop .iotupdate file here";
            document.getElementById("dz-sub").textContent   = "or click to browse";
            document.getElementById("file-input").value     = "";
            state.selectedFile = null;
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
    if (b) {
        b.textContent = label;
        var cls = "idle";
        if (["uploading", "extracting"].indexOf(stage) !== -1) cls = "uploading";
        else if (stage === "verifying") cls = "verifying";
        else if (["queued", "applying"].indexOf(stage) !== -1) cls = "applying";
        else if (stage === "rebooting") cls = "rebooting";
        else if (stage === "error")     cls = "error";
        b.className = "badge-" + cls;
    }
    // Update header status pill
    var dot = document.getElementById("hdr-status-dot");
    var txt = document.getElementById("hdr-status");
    if (dot && txt) {
        txt.textContent = label;
        dot.className = "pill-dot " + (stage === "error" ? "red" : stage === "idle" ? "green" : stage === "rebooting" ? "orange" : "blue");
        var activeStagesForDot = ["uploading", "extracting", "verifying", "queued", "applying", "rebooting"];
        if (activeStagesForDot.indexOf(stage) !== -1) {
            dot.classList.add("animating");
        } else {
            dot.classList.remove("animating");
        }
    }
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
            state.bootcPoller = setTimeout(pollBootcStatus, 10000);
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
        if (m) state.currentVersion = m[1];
    }

    // Update header version pill
    var hdrVersion = document.getElementById("hdr-version");
    if (hdrVersion) {
        var imgTag = booted.image ? (booted.image.match(/:(.+)$/) || [])[1] : null;
        hdrVersion.textContent = imgTag ? imgTag : (booted.version || "v—");
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
    state.selectedFile = file;
    clearError();
    loadDiskSpace();
    document.getElementById("dz-title").textContent = file.name;
    document.getElementById("dz-sub").textContent =
        (file.size / 1024 / 1024).toFixed(1) + " MB — uploading…";
    uploadAndPreview(file);
}

// ── Chunked upload via cockpit.http() ─────────────────────────────────────────
function uploadAndPreview(file) {
    resetState();
    var totalChunks = Math.ceil(file.size / CHUNK_SIZE);

    api.request({ method: "POST", path: "/upload/start", body: "" })
        .then(function() {
            document.getElementById("progress-area").style.display = "block";
            state.uploadStartTime = Date.now();
            state.uploadedBytes   = 0;
            return sendChunks(file, totalChunks, 0);
        })
        .then(function() {
            var speedEl = document.getElementById("speed-label");
            if (speedEl) { speedEl.className = "speed-label"; speedEl.textContent = ""; }
            return api.get("/status");
        })
        .then(function(text) {
            var s = JSON.parse(text);
            document.getElementById("progress-area").style.display = "none";
            clearProgress();
            if (s.stage === "error") {
                showError(s.error || s.message || "Bundle verification failed.");
                return;
            }
            if (s.version_info) {
                state.versionPreview = s.version_info;
                showVersionPreview(state.versionPreview);
            } else {
                showError("Upload complete but version info missing from bundle.");
            }
        })
        .catch(function(err) {
            document.getElementById("progress-area").style.display = "none";
            clearProgress();
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
            var isLast = (index + 1 >= totalChunks);
            // Show verifying animation *before* the request so user sees it while server hashes
            if (isLast) {
                updateProgress(99, "Verifying bundle integrity…");
                document.getElementById("progress-fill").classList.add("progress-pulsing");
            }
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
                if (isLast) {
                    document.getElementById("progress-fill").classList.remove("progress-pulsing");
                    updateProgress(100, "Verification complete ✓");
                } else {
                    var pct = Math.round(((index + 1) / totalChunks) * 100);
                    updateProgress(pct, "Uploading… " + pct + "%");
                }
                state.uploadedBytes += chunk.size;
                var elapsed = (Date.now() - state.uploadStartTime) / 1000;
                if (elapsed > 1) {
                    var mbps = (state.uploadedBytes / 1048576) / elapsed;
                    var remaining = file.size - state.uploadedBytes;
                    var etaSec = remaining / (state.uploadedBytes / elapsed);
                    var etaStr = etaSec > 60
                        ? Math.floor(etaSec / 60) + "m " + Math.round(etaSec % 60) + "s"
                        : Math.round(etaSec) + "s";
                    var speedEl = document.getElementById("speed-label");
                    if (speedEl && !isLast) {
                        speedEl.className = "speed-label visible";
                        speedEl.textContent = "⬆ " + mbps.toFixed(1) + " MB/s  ~" + etaStr + " remaining";
                    }
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

    var clRow = document.getElementById("pv-changelog-row");
    var clEl  = document.getElementById("pv-changelog");
    if (info.changelog && clRow && clEl) {
        var cl = Array.isArray(info.changelog) ? info.changelog.join("\n") : String(info.changelog);
        clEl.textContent = cl;
        clRow.style.display = "";
    } else if (clRow) {
        clRow.style.display = "none";
    }

    document.getElementById("version-preview").style.display = "block";
    document.getElementById("downgrade-warning").style.display = isDowngrade() ? "block" : "none";

    var applyBtn = document.getElementById("btn-apply");
    applyBtn.textContent = info.dry_run ? "Apply v" + stripV(info.version) + " (dry run)" : "Apply & Reboot v" + stripV(info.version);
    applyBtn.disabled    = isDowngrade() && !document.getElementById("allow-downgrade").checked;

    document.getElementById("dz-sub").textContent =
        (state.selectedFile.size / 1024 / 1024).toFixed(1) + " MB — ready to apply";
}

function isDowngrade() {
    if (!state.currentVersion || !state.versionPreview || !state.versionPreview.version) return false;
    return versionCompare(state.versionPreview.version, state.currentVersion) <= 0;
}

function stripV(v) { return v ? v.replace(/^v/i, "") : v; }

function versionCompare(a, b) {
    // Strip leading "v", split on "-" to separate pre-release suffix, then compare numeric parts
    var norm = function(s) {
        var base = s.replace(/^v/, "").split("-")[0]; // strip pre-release suffix
        return base.split(".").map(function(p) { return parseInt(p, 10) || 0; });
    };
    var pa = norm(a), pb = norm(b);
    for (var i = 0; i < Math.max(pa.length, pb.length); i++) {
        var diff = (pa[i] || 0) - (pb[i] || 0);
        if (diff !== 0) return diff;
    }
    // If numeric parts equal, a pre-release suffix means older (e.g. v2-rc1 < v2)
    var hasPre = function(s) { return s.replace(/^v/, "").indexOf("-") !== -1; };
    if (hasPre(a) && !hasPre(b)) return -1;
    if (!hasPre(a) && hasPre(b)) return 1;
    return 0;
}

// ── Apply / Cancel ────────────────────────────────────────────────────────────
function applyUpdate() {
    if (!state.versionPreview) return;
    showConfirmModal(
        "Apply Update " + state.versionPreview.version + "?",
        state.versionPreview.dry_run
            ? "This is a dry run — no actual changes will be made."
            : "The device will reboot after the update is applied. Make sure no critical processes are running.",
        function() {
            var applyBtn = document.getElementById("btn-apply");
            applyBtn.disabled = true;
            applyBtn.textContent = "Applying…";
            api.request({ method: "POST", path: "/upload/apply", body: "" })
                .catch(function(err) {
                    applyBtn.disabled = false;
                    applyBtn.textContent = "Retry Apply " + state.versionPreview.version;
                    showError("Failed to trigger update: " + (err.message || err.problem || String(err)));
                });
        }
    );
}

function cancelUpload() {
    api.request({ method: "POST", path: "/upload/cancel", body: "" })
        .then(function() {
            resetState();
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
            showToast("info", "Rollback triggered. Device is rebooting to " + (r.rolling_back_to || rbImage) + ". Reconnect in ~60 seconds.");
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
            var emptyEl = document.getElementById("history-empty");
            emptyEl.style.display = "block";
            emptyEl.innerHTML = 'Could not load history. <button class="btn btn-secondary btn-sm" onclick="loadHistory()" style="margin-left:8px">↻ Retry</button>';
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
        var sha = h.sha256 ? (
            '<span class="hash-display" title="' + esc(h.sha256) + '">' +
            h.sha256.substring(0, 16) + '…</span> ' +
            '<button class="copy-hash-btn" onclick="copyHash(\'' + esc(h.sha256) + '\')" title="Copy SHA256">��</button>'
        ) : "";
        var snippetHtml = "";
        if (h.status === "error" && h.log_snippet && h.log_snippet.length) {
            var snippetId = "snippet-" + i;
            var snippetLines = h.log_snippet.map(function(l) { return esc(l); }).join("\n");
            snippetHtml = '<br><button class="snippet-toggle" onclick="toggleSnippet(\'' + snippetId + '\')">▶ Show log</button>' +
                          '<div class="log-snippet" id="' + snippetId + '">' + snippetLines + '</div>';
        }
        var dotClass = "hist-dot hist-dot-" + (h.status || "default");
        if (["applied","error","dry_run","applying"].indexOf(h.status) === -1) dotClass = "hist-dot hist-dot-default";
        rows.push(
            "<tr>" +
            "<td style='padding:8px 8px 8px 16px;width:26px;vertical-align:top'><div class='" + dotClass + "'></div></td>" +
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
var logOpen = true;  // log is always open now

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
        if (line.indexOf("[ERROR]") !== -1)   cls = "log-err";
        else if (line.indexOf("[SUCCESS]") !== -1 || line.indexOf("[COMPLETE]") !== -1) cls = "log-ok";
        else if (line.indexOf("[WARNING]") !== -1) cls = "log-warn";
        var escaped = esc(line).replace(/(\[[\dT:Z\-]+\])/g, '<span class="log-ts">$1</span>');
        return cls ? '<span class="' + cls + '">' + escaped + '</span>' : escaped;
    }).join("\n");
    out.innerHTML = html;
    out.scrollTop = out.scrollHeight;
}

var _progressTarget = 0;
var _progressCurrent = 0;
var _progressTimer = null;

function updateProgress(pct, label) {
    _progressTarget = pct;
    document.getElementById("progress-fill").style.width = pct + "%";
    if (label) document.getElementById("progress-label").textContent = label;
    if (_progressTimer) return;
    _progressTimer = setInterval(function() {
        if (_progressCurrent < _progressTarget) {
            _progressCurrent = Math.min(_progressCurrent + 1, _progressTarget);
            // label is already set above — no need to update text here
        } else {
            clearInterval(_progressTimer);
            _progressTimer = null;
        }
    }, 16);
}

function clearProgress() {
    _progressTarget = 0;
    _progressCurrent = 0;
    if (_progressTimer) { clearInterval(_progressTimer); _progressTimer = null; }
}

function showError(msg) {
    showToast("error", msg);
}

function clearError() {
    // No-op — errors are toasts now, they auto-dismiss
}

function esc(s) {
    return String(s || "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

function copyHash(hash) {
    if (navigator.clipboard) {
        navigator.clipboard.writeText(hash).catch(function() {});
    }
}

// ── Disk space widget (H-E) ───────────────────────────────────────────────────
function loadDiskSpace() {
    api.get("/disk-space")
        .then(function(text) {
            var d = JSON.parse(text);
            var widget = document.getElementById("disk-space-widget");
            var fill   = document.getElementById("disk-bar-fill");
            var label  = document.getElementById("disk-avail-label");
            var warn   = document.getElementById("disk-warn-msg");
            widget.style.display = "block";
            var pct = Math.min(Math.round((d.available_gb / (d.required_gb * 2)) * 100), 100);
            fill.style.width = pct + "%";
            fill.className = "disk-bar-fill " + (d.ok ? (pct > 60 ? "ok" : "warn") : "danger");
            label.textContent = d.available_gb + " GB free";
            label.className = "disk-info" + (d.ok ? "" : " danger");
            if (!d.ok) {
                warn.style.display = "block";
                warn.textContent = "⚠ Need " + d.required_gb + " GB — free up space before uploading.";
            } else {
                warn.style.display = "none";
            }
        })
        .catch(function() {}); // silently ignore if endpoint not available
}

// ── Confirm modal (H-C) ───────────────────────────────────────────────────────
function showConfirmModal(title, body, onConfirm) {
    var overlay = document.createElement("div");
    overlay.className = "modal-overlay";
    overlay.innerHTML =
        '<div class="modal-box">' +
            '<div class="modal-title">' + esc(title) + '</div>' +
            '<div class="modal-body">' + esc(body) + '</div>' +
            '<div class="modal-actions">' +
                '<button class="btn btn-secondary" id="modal-cancel">Cancel</button>' +
                '<button class="btn btn-primary" id="modal-confirm">Confirm</button>' +
            '</div>' +
        '</div>';
    document.body.appendChild(overlay);
    overlay.querySelector("#modal-cancel").addEventListener("click", function() { overlay.remove(); });
    overlay.querySelector("#modal-confirm").addEventListener("click", function() {
        overlay.remove();
        onConfirm();
    });
    overlay.addEventListener("click", function(e) { if (e.target === overlay) overlay.remove(); });
}

// ── URL fetch (H-B) ──────────────────────────────────────────────────────────
function fetchFromUrl() {
    var url = (document.getElementById("fetch-url-input").value || "").trim();
    var errEl = document.getElementById("fetch-url-error");
    errEl.style.display = "none";

    if (!url) { errEl.textContent = "Enter a URL."; errEl.style.display = "block"; return; }
    if (!url.endsWith(".iotupdate")) {
        errEl.textContent = "URL must end with .iotupdate"; errEl.style.display = "block"; return;
    }

    var btn = document.getElementById("btn-fetch-url");
    btn.disabled = true;
    btn.textContent = "Fetching…";

    api.request({ method: "POST", path: "/fetch-url", body: JSON.stringify({ url: url }),
                  headers: { "Content-Type": "application/json" } })
        .then(function() {
            btn.textContent = "⬇ Fetch";
            btn.disabled = false;
            document.getElementById("progress-area").style.display = "block";
            showToast("info", "Fetching bundle from URL… check progress bar.");
        })
        .catch(function(err) {
            btn.textContent = "⬇ Fetch";
            btn.disabled = false;
            var msg = "";
            try { msg = JSON.parse(err.message || "{}").error || err.message; } catch(e) { msg = String(err); }
            errEl.textContent = msg || "Fetch failed.";
            errEl.style.display = "block";
        });
}
