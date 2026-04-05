/* update.js — Cockpit IoT Updater page logic */

const SIDECAR = "http://127.0.0.1:8088";
const CHUNK_SIZE = 8 * 1024 * 1024; // 8 MB per chunk

let selectedFile = null;
let versionPreview = null;
let currentVersion = null;  // from history — last applied
let statusPoller = null;

// ── Tab switching ────────────────────────────────────────────────────────────
function switchTab(tab) {
    document.querySelectorAll(".tab-btn").forEach((b, i) => {
        b.classList.toggle("active", (i === 0 && tab === "upload") || (i === 1 && tab === "history"));
    });
    document.getElementById("tab-upload").classList.toggle("active", tab === "upload");
    document.getElementById("tab-history").classList.toggle("active", tab === "history");

    if (tab === "history") loadHistory();
}

// ── Boot: load status + history ──────────────────────────────────────────────
window.addEventListener("load", () => {
    loadCurrentDeployment();
    pollStatus();
    setupDropZone();

    document.getElementById("file-input").addEventListener("change", e => {
        if (e.target.files[0]) handleFileSelected(e.target.files[0]);
    });
});

// ── Current deployment (from history last-applied entry) ─────────────────────
async function loadCurrentDeployment() {
    try {
        const history = await fetchJSON("/history");
        const applied = history.filter(h => h.status === "applied");
        const el = document.getElementById("current-info");
        if (applied.length === 0) {
            el.textContent = "No updates applied via this tool yet. Current version is the factory image.";
            return;
        }
        const last = applied[applied.length - 1];
        currentVersion = last.version;
        el.innerHTML = `
            <table style="border-collapse:collapse;font-size:0.9rem">
                <tr><td style="padding:3px 8px;color:#6a6e73;font-weight:600">Version</td><td style="padding:3px 8px">${esc(last.version)}</td></tr>
                <tr><td style="padding:3px 8px;color:#6a6e73;font-weight:600">Applied</td><td style="padding:3px 8px">${esc(last.applied_at_complete || last.applied_at)}</td></tr>
                <tr><td style="padding:3px 8px;color:#6a6e73;font-weight:600">Commit</td><td style="padding:3px 8px;font-family:monospace;font-size:0.8rem">${esc(last.to_commit.slice(0, 16))}…</td></tr>
            </table>`;
    } catch {
        document.getElementById("current-info").textContent = "Could not reach updater sidecar (is iot-updater.service running?)";
    }
}

// ── Status polling ───────────────────────────────────────────────────────────
async function pollStatus() {
    try {
        const s = await fetchJSON("/status");
        renderStatus(s);
    } catch {
        setBadge("error", "Sidecar unreachable");
    }
    statusPoller = setTimeout(pollStatus, 2000);
}

function renderStatus(s) {
    setBadge(s.stage, stageLabel(s.stage));

    const progressArea = document.getElementById("progress-area");
    const isActive = ["uploading", "extracting", "queued", "applying", "rebooting"].includes(s.stage);
    progressArea.style.display = isActive ? "block" : "none";
    if (isActive) {
        document.getElementById("progress-fill").style.width = s.progress_pct + "%";
        document.getElementById("progress-label").textContent = s.message || `${s.progress_pct}%`;
    }

    const errEl = document.getElementById("error-msg");
    errEl.style.display = s.stage === "error" ? "block" : "none";
    if (s.stage === "error") errEl.textContent = s.message;

    // Buttons
    const applyBtn = document.getElementById("btn-apply");
    const cancelBtn = document.getElementById("btn-cancel");

    if (s.stage === "idle" && versionPreview) {
        applyBtn.disabled = isDowngrade() && !document.getElementById("allow-downgrade").checked;
        applyBtn.style.display = "";
        cancelBtn.style.display = "none";
    } else if (isActive) {
        applyBtn.style.display = "none";
        cancelBtn.style.display = s.stage === "uploading" ? "" : "none";
    } else if (s.stage === "error") {
        applyBtn.disabled = false;
        applyBtn.style.display = "";
        applyBtn.textContent = "Retry Upload";
        cancelBtn.style.display = "";
    } else {
        applyBtn.disabled = !versionPreview;
        applyBtn.style.display = "";
        cancelBtn.style.display = "none";
    }

    if (s.stage === "rebooting") {
        applyBtn.style.display = "none";
        cancelBtn.style.display = "none";
    }
}

function stageLabel(stage) {
    return {
        idle: "Idle",
        uploading: "Uploading…",
        extracting: "Extracting…",
        queued: "Queued",
        applying: "Applying…",
        rebooting: "Rebooting…",
        error: "Error",
    }[stage] || stage;
}

function setBadge(stage, label) {
    const b = document.getElementById("status-badge");
    b.textContent = label;
    b.className = "badge-" + (["uploading","extracting","queued"].includes(stage) ? "uploading" :
                               ["applying"].includes(stage) ? "applying" :
                               stage === "rebooting" ? "rebooting" :
                               stage === "error" ? "error" : "idle");
}

// ── Drop zone ────────────────────────────────────────────────────────────────
function setupDropZone() {
    const zone = document.getElementById("drop-zone");
    zone.addEventListener("dragover", e => { e.preventDefault(); zone.classList.add("dragover"); });
    zone.addEventListener("dragleave", () => zone.classList.remove("dragover"));
    zone.addEventListener("drop", e => {
        e.preventDefault();
        zone.classList.remove("dragover");
        const f = e.dataTransfer.files[0];
        if (f) handleFileSelected(f);
    });
}

async function handleFileSelected(file) {
    if (!file.name.endsWith(".iotupdate")) {
        showError("Please select a .iotupdate file generated by make-bundle.sh");
        return;
    }
    selectedFile = file;
    document.getElementById("error-msg").style.display = "none";

    // Show file info while we upload to preview endpoint
    document.getElementById("drop-zone").querySelector("strong").textContent = file.name;
    document.getElementById("drop-zone").querySelector("p").textContent =
        `${(file.size / 1024 / 1024 / 1024).toFixed(2)} GB — uploading…`;

    await uploadAndPreview(file);
}

// ── Chunked upload → preview ─────────────────────────────────────────────────
async function uploadAndPreview(file) {
    const totalChunks = Math.ceil(file.size / CHUNK_SIZE);

    // Tell sidecar we're starting
    try {
        const r = await fetch(`${SIDECAR}/upload/start`, { method: "POST" });
        if (!r.ok) { const j = await r.json(); showError(j.error); return; }
    } catch (e) { showError("Cannot reach sidecar. Is iot-updater.service running?"); return; }

    document.getElementById("progress-area").style.display = "block";

    for (let i = 0; i < totalChunks; i++) {
        const chunk = file.slice(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE);
        try {
            const resp = await fetch(`${SIDECAR}/upload`, {
                method: "POST",
                headers: {
                    "Content-Type": "application/octet-stream",
                    "X-Chunk-Index": String(i),
                    "X-Total-Chunks": String(totalChunks),
                },
                body: chunk,
            });
            const j = await resp.json();
            if (!resp.ok) { showError(j.error || "Upload failed"); return; }
            updateProgress(j.progress, `Uploading… ${j.progress}%`);
        } catch (e) {
            showError("Upload interrupted: " + e.message);
            return;
        }
    }

    // Fetch version preview from sidecar (it extracted version.json)
    try {
        const s = await fetchJSON("/status");
        if (s.version_info) {
            versionPreview = s.version_info;
            showVersionPreview(versionPreview);
        }
    } catch { /* ignore */ }

    document.getElementById("progress-area").style.display = "none";
}

function showVersionPreview(info) {
    document.getElementById("pv-version").textContent = info.version || "—";
    document.getElementById("pv-date").textContent = info.build_date || "—";
    document.getElementById("pv-desc").textContent = info.description || "—";
    document.getElementById("pv-from").textContent = (info.from_commit || "").slice(0, 24) + "…";
    document.getElementById("pv-to").textContent = (info.to_commit || "").slice(0, 24) + "…";
    document.getElementById("version-preview").style.display = "block";

    // Downgrade check
    if (isDowngrade()) {
        document.getElementById("downgrade-warning").style.display = "block";
        document.getElementById("allow-downgrade").addEventListener("change", () => {
            document.getElementById("btn-apply").disabled =
                isDowngrade() && !document.getElementById("allow-downgrade").checked;
        });
    } else {
        document.getElementById("downgrade-warning").style.display = "none";
    }

    document.getElementById("btn-apply").textContent = `Apply v${info.version}`;
    document.getElementById("btn-apply").disabled = isDowngrade() && !document.getElementById("allow-downgrade").checked;
    document.getElementById("drop-zone").querySelector("p").textContent =
        `${(selectedFile.size / 1024 / 1024 / 1024).toFixed(2)} GB — ready to apply`;
}

function isDowngrade() {
    if (!currentVersion || !versionPreview?.version) return false;
    return versionCompare(versionPreview.version, currentVersion) <= 0;
}

function versionCompare(a, b) {
    const pa = a.split(".").map(Number), pb = b.split(".").map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const diff = (pa[i] || 0) - (pb[i] || 0);
        if (diff !== 0) return diff;
    }
    return 0;
}

// ── Apply ────────────────────────────────────────────────────────────────────
async function applyUpdate() {
    if (!versionPreview) return;
    if (!confirm(`Apply update v${versionPreview.version}?\n\nThe device will reboot automatically after the update is applied.`)) return;

    try {
        const r = await fetch(`${SIDECAR}/upload/apply`, { method: "POST" });
        const j = await r.json();
        if (!r.ok) { showError(j.error); return; }
    } catch (e) { showError("Failed to trigger update: " + e.message); }
}

async function cancelUpload() {
    try {
        await fetch(`${SIDECAR}/upload/cancel`, { method: "POST" });
        versionPreview = null;
        selectedFile = null;
        document.getElementById("version-preview").style.display = "none";
        document.getElementById("drop-zone").querySelector("strong").textContent = "Drop .iotupdate file here";
        document.getElementById("drop-zone").querySelector("p").textContent = "or click to browse";
        document.getElementById("btn-apply").disabled = true;
        document.getElementById("btn-apply").textContent = "Apply Update";
        document.getElementById("btn-cancel").style.display = "none";
    } catch (e) { showError("Cancel failed: " + e.message); }
}

// ── History ──────────────────────────────────────────────────────────────────
async function loadHistory() {
    try {
        const history = await fetchJSON("/history");
        const tbody = document.getElementById("history-body");
        const tbl = document.getElementById("history-table");
        const empty = document.getElementById("history-empty");

        if (history.length === 0) {
            tbl.style.display = "none";
            empty.style.display = "block";
            return;
        }
        tbl.style.display = "table";
        empty.style.display = "none";

        tbody.innerHTML = [...history].reverse().map(h => `
            <tr>
                <td><strong>${esc(h.version)}</strong></td>
                <td>${esc(h.applied_at_complete || h.applied_at || "—")}</td>
                <td>${esc(h.description || "—")}</td>
                <td class="mono">${esc((h.to_commit || "").slice(0, 12))}…</td>
                <td><span class="status-pill pill-${esc(h.status)}">${esc(h.status)}</span></td>
            </tr>`).join("");
    } catch {
        document.getElementById("history-empty").textContent = "Could not load history (sidecar unreachable).";
        document.getElementById("history-empty").style.display = "block";
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────
async function fetchJSON(path) {
    const r = await fetch(SIDECAR + path);
    return r.json();
}

function updateProgress(pct, label) {
    document.getElementById("progress-fill").style.width = pct + "%";
    document.getElementById("progress-label").textContent = label;
}

function showError(msg) {
    const el = document.getElementById("error-msg");
    el.textContent = msg;
    el.style.display = "block";
}

function esc(s) {
    return String(s || "").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
}
