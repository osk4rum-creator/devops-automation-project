// StatusPulse dashboard. Plain JavaScript, no build step.
// Every value that comes from users (monitor names, URLs, errors) goes
// through esc() before it is put into HTML, so it can't inject markup (XSS).
"use strict";

const REFRESH_MS = 10000;
const $ = (sel) => document.querySelector(sel);
const state = { monitors: [], openDetailId: null, timer: null, readOnly: false };

// Admin token for read-only demo mode: kept in sessionStorage (this tab only),
// sent as "Authorization: Bearer ..." on API calls.
function getToken() { try { return sessionStorage.getItem("adminToken") || ""; } catch { return ""; } }
function setToken(t) { try { t ? sessionStorage.setItem("adminToken", t) : sessionStorage.removeItem("adminToken"); } catch { /* ignore */ } }

// ---------- helpers ----------
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function api(path, options = {}) {
  const headers = { "Content-Type": "application/json" };
  const token = getToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`/api${path}`, { headers, ...options });
  if (res.status === 204) return null;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `Request failed (${res.status})`);
  return body;
}

function toast(message, isError = false) {
  const el = $("#toast");
  el.textContent = message;
  el.className = `toast show${isError ? " error" : ""}`;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (el.className = "toast"), 3500);
}

function ago(iso) {
  if (!iso) return "never";
  const s = Math.max(0, Math.round((Date.now() - new Date(iso)) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

function duration(fromIso, toIso) {
  const s = Math.round(((toIso ? new Date(toIso) : Date.now()) - new Date(fromIso)) / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}

const fmtMs = (ms) => (ms == null ? "–" : `${Math.round(ms)} ms`);
const fmtPct = (p) => (p == null ? "–" : `${Number(p).toFixed(p >= 99.95 || p === 0 ? 0 : 2)}%`);
const time = (iso) => new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

function statusOf(m) {
  if (m.paused) return { cls: "paused", label: "Paused" };
  if (m.status === "up") return { cls: "up", label: "Up" };
  if (m.status === "down") return { cls: "down", label: "Down" };
  return { cls: "pending", label: "Pending" };
}

const ICONS = {
  pause: '<svg viewBox="0 0 24 24"><path d="M9 5v14M15 5v14"/></svg>',
  play: '<svg viewBox="0 0 24 24"><path d="M7 5l12 7-12 7z"/></svg>',
  trash: '<svg viewBox="0 0 24 24"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/></svg>',
  x: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  check: '<svg viewBox="0 0 24 24"><path d="M5 12l5 5 9-10"/></svg>',
  file: '<svg viewBox="0 0 24 24"><path d="M14 3H6v18h12V7zM14 3v4h4"/></svg>',
};

// ---------- sparkline: one bar per check, height = response time ----------
function sparkline(points) {
  const slots = 30, w = 132, h = 30, gap = 1.4;
  const bw = (w - gap * (slots - 1)) / slots;
  const max = Math.max(200, ...points.filter((p) => p.ok).map((p) => p.ms || 0));
  const pad = slots - points.length;
  let bars = "";
  for (let i = 0; i < slots; i++) {
    const x = (i * (bw + gap)).toFixed(1);
    const p = points[i - pad];
    if (!p) { bars += `<rect class="none" x="${x}" y="${h - 3}" width="${bw.toFixed(1)}" height="3" rx="1"/>`; continue; }
    const bh = p.ok ? Math.max(4, ((p.ms || 0) / max) * (h - 2)) : h;
    bars += `<rect class="${p.ok ? "ok" : "fail"}" x="${x}" y="${(h - bh).toFixed(1)}" width="${bw.toFixed(1)}" height="${bh.toFixed(1)}" rx="1"/>`;
  }
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" aria-hidden="true">${bars}</svg>`;
}

// ---------- summary ----------
function renderSummary(s) {
  $("#stat-up").textContent = s.up;
  $("#stat-up-hint").textContent = `of ${s.total} monitors${s.paused ? ` · ${s.paused} paused` : ""}`;
  const down = $("#stat-down");
  down.textContent = s.down;
  down.className = `stat-value ${s.down > 0 ? "down-text" : ""}`;
  $("#stat-down-hint").textContent = `${s.open_incidents} open incident${s.open_incidents === 1 ? "" : "s"}`;
  $("#stat-uptime").textContent = fmtPct(s.uptime_24h);
  $("#stat-uptime-hint").textContent = `${s.checks_24h} checks in 24h`;
  $("#stat-latency").textContent = fmtMs(s.avg_response_ms);

  const sub = $("#hero-subtitle");
  if (s.total === 0) sub.textContent = "No monitors yet. Add your first one to start tracking uptime.";
  else if (s.down > 0) sub.textContent = `${s.down} service${s.down === 1 ? " is" : "s are"} down right now.`;
  else if (s.pending > 0 && s.up === 0) sub.textContent = "Running the first checks…";
  else sub.textContent = "All monitored services are operational.";
}

// ---------- monitor list ----------
function renderMonitors(list) {
  state.monitors = list;
  $("#monitor-count").textContent = list.length ? `${list.length} total` : "";
  const box = $("#monitor-list");
  if (!list.length) {
    box.innerHTML = '<div class="empty">No monitors yet. Click <strong>Add monitor</strong> to watch your first website or API.</div>';
    return;
  }
  box.innerHTML = list.map((m) => {
    const st = statusOf(m);
    const note = m.status === "down" && !m.paused
      ? `<div class="monitor-note">${esc(m.last_error || "Down")} · since ${esc(ago(m.status_since))}</div>`
      : `<div class="monitor-url">${esc(m.url)}</div>`;
    return `
      <div class="monitor ${m.paused ? "is-paused" : ""}" data-id="${m.id}" tabindex="0" role="button"
           aria-label="${esc(m.name)}: ${st.label}">
        <span class="dot ${st.cls}" title="${st.label}"></span>
        <div class="monitor-info">
          <div class="monitor-name">${esc(m.name)}</div>
          ${note}
        </div>
        <div class="spark-cell">${sparkline(m.spark)}</div>
        <div class="metric">${fmtMs(m.last_response_ms)}<small>${esc(ago(m.last_checked_at))}</small></div>
        <div class="metric metric-uptime">${fmtPct(m.uptime_24h)}<small>uptime</small></div>
        <div class="actions">
          <button class="icon-btn" type="button" data-action="${m.paused ? "resume" : "pause"}"
                  title="${m.paused ? "Resume" : "Pause"}" aria-label="${m.paused ? "Resume" : "Pause"} ${esc(m.name)}">
            ${m.paused ? ICONS.play : ICONS.pause}</button>
          <button class="icon-btn danger" type="button" data-action="delete" title="Delete" aria-label="Delete ${esc(m.name)}">
            ${ICONS.trash}</button>
        </div>
      </div>`;
  }).join("");
}

// ---------- incidents ----------
function renderIncidents(list) {
  const box = $("#incident-list");
  if (!list.length) { box.innerHTML = '<li class="empty">No incidents. Everything has been stable.</li>'; return; }
  box.innerHTML = list.map((i) => {
    const open = !i.resolved_at;
    return `<li>
      <span class="feed-icon ${open ? "open" : "resolved"}">${open ? ICONS.x : ICONS.check}</span>
      <div>
        <div class="feed-title">${esc(i.monitor_name)} ${open ? "is down" : "recovered"}</div>
        <div class="feed-meta">${open ? "Ongoing for" : "Down for"} ${esc(duration(i.started_at, i.resolved_at))} · started ${esc(ago(i.started_at))}</div>
        ${i.cause ? `<div class="feed-meta">${esc(i.cause)}</div>` : ""}
      </div></li>`;
  }).join("");
}

// ---------- reports ----------
async function loadReports() {
  try {
    const data = await api("/reports");
    const badge = $("#s3-badge");
    badge.textContent = data.enabled ? "S3 connected" : "S3 off";
    badge.className = `badge ${data.enabled ? "on" : ""}`;
    $("#report-btn").disabled = !data.enabled;
    $("#report-list").innerHTML = data.reports.map((r) => `
      <li><span class="feed-icon resolved">${ICONS.file}</span>
        <div><a href="${esc(r.url)}" rel="noopener noreferrer">${esc(r.s3_key.split("/").pop())}</a>
        <div class="feed-meta">${r.monitors} monitors · ${esc(ago(r.created_at))}</div></div></li>`).join("");
  } catch { /* reports are optional */ }
}

async function exportReport() {
  const btn = $("#report-btn");
  btn.disabled = true;
  btn.textContent = "Exporting…";
  try {
    const report = await api("/reports", { method: "POST" });
    toast("Report saved to S3 - download starting");
    window.location.href = report.url;
    loadReports();
  } catch (e) {
    toast(e.message, true);
  } finally {
    btn.disabled = false;
    btn.textContent = "Export 24h report";
  }
}

// ---------- detail dialog ----------
function chart(checks) {
  const data = [...checks].reverse();               // oldest -> newest
  if (!data.length) return '<p class="empty">No checks yet.</p>';
  const W = 760, H = 170, L = 44, R = 8, T = 10, B = 22;
  const okMs = data.filter((c) => c.ok && c.response_ms != null).map((c) => c.response_ms);
  const max = Math.max(100, ...okMs) * 1.15;
  const x = (i) => L + (data.length === 1 ? (W - L - R) / 2 : (i / (data.length - 1)) * (W - L - R));
  const y = (ms) => T + (1 - ms / max) * (H - T - B);
  let grid = "";
  for (const f of [0, 0.5, 1]) {
    const v = Math.round(max * f), yy = y(v).toFixed(1);
    grid += `<line class="grid" x1="${L}" x2="${W - R}" y1="${yy}" y2="${yy}"/><text x="${L - 6}" y="${(+yy + 4).toFixed(1)}" text-anchor="end">${v}ms</text>`;
  }
  const pts = data.map((c, i) => (c.ok && c.response_ms != null ? [x(i), y(c.response_ms)] : null));
  const line = pts.filter(Boolean).map((p) => p.map((n) => n.toFixed(1)).join(",")).join(" ");
  const okPts = pts.filter(Boolean);
  const area = okPts.length > 1
    ? `<polygon class="area" points="${okPts[0][0].toFixed(1)},${H - B} ${line} ${okPts[okPts.length - 1][0].toFixed(1)},${H - B}"/>` : "";
  const fails = data.map((c, i) => (c.ok ? "" : `<circle class="fail" cx="${x(i).toFixed(1)}" cy="${(H - B - 4).toFixed(1)}" r="4"><title>${esc(c.error || "failed")}</title></circle>`)).join("");
  const labels = `<text x="${L}" y="${H - 5}">${esc(time(data[0].checked_at))}</text><text x="${W - R}" y="${H - 5}" text-anchor="end">${esc(time(data[data.length - 1].checked_at))}</text>`;
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="Response time chart">${grid}${area}<polyline class="line" points="${line}"/>${fails}${labels}</svg>`;
}

async function openDetail(id) {
  state.openDetailId = id;
  try {
    const m = await api(`/monitors/${id}`);
    const st = statusOf(m);
    $("#detail-name").textContent = m.name;
    const link = $("#detail-url");
    link.textContent = m.url;
    link.href = m.url;
    const okChecks = m.checks.filter((c) => c.ok);
    const avg = okChecks.length ? okChecks.reduce((a, c) => a + (c.response_ms || 0), 0) / okChecks.length : null;
    $("#detail-stats").innerHTML = `
      <div class="mini"><span>Status</span><strong class="${st.cls === "down" ? "down-text" : st.cls === "up" ? "up-text" : ""}">${st.label}</strong></div>
      <div class="mini"><span>Since</span><strong>${esc(duration(m.status_since))}</strong></div>
      <div class="mini"><span>Avg (last ${m.checks.length})</span><strong>${fmtMs(avg)}</strong></div>
      <div class="mini"><span>Interval</span><strong>${m.interval_seconds}s</strong></div>`;
    $("#detail-chart").innerHTML = chart(m.checks);
    $("#detail-checks").innerHTML = `<thead><tr><th>Time</th><th>Result</th><th>Code</th><th>Response</th><th>Error</th></tr></thead><tbody>${
      m.checks.map((c) => `<tr><td>${esc(time(c.checked_at))}</td>
        <td><span class="pill ${c.ok ? "up" : "down"}">${c.ok ? "OK" : "FAIL"}</span></td>
        <td>${c.status_code ?? "–"}</td><td>${fmtMs(c.response_ms)}</td>
        <td class="err">${esc(c.error || "")}</td></tr>`).join("") || '<tr><td colspan="5" class="muted">No checks yet</td></tr>'
    }</tbody>`;
    $("#detail-incidents").innerHTML = m.incidents.length
      ? m.incidents.map((i) => `<li><span class="feed-icon ${i.resolved_at ? "resolved" : "open"}">${i.resolved_at ? ICONS.check : ICONS.x}</span>
          <div><div class="feed-title">${i.resolved_at ? "Resolved" : "Ongoing"} · ${esc(duration(i.started_at, i.resolved_at))}</div>
          <div class="feed-meta">${esc(new Date(i.started_at).toLocaleString())}</div>
          ${i.cause ? `<div class="feed-meta">${esc(i.cause)}</div>` : ""}</div></li>`).join("")
      : '<li class="empty">No incidents for this monitor.</li>';
    const dlg = $("#detail-dialog");
    if (!dlg.open) dlg.showModal();
  } catch (e) {
    toast(e.message, true);
  }
}

// ---------- actions ----------
async function onListClick(event) {
  const row = event.target.closest(".monitor");
  if (!row) return;
  const id = Number(row.dataset.id);
  const button = event.target.closest("button[data-action]");
  if (!button) return openDetail(id);
  event.stopPropagation();
  const action = button.dataset.action;
  const monitor = state.monitors.find((m) => m.id === id);
  try {
    if (action === "delete") {
      if (!confirm(`Delete "${monitor?.name}" and its history?`)) return;
      await api(`/monitors/${id}`, { method: "DELETE" });
      toast("Monitor deleted");
    } else {
      await api(`/monitors/${id}/${action}`, { method: "POST" });
      toast(action === "pause" ? "Monitoring paused" : "Monitoring resumed");
    }
    refresh();
  } catch (e) {
    toast(e.message, true);
  }
}

async function onAddSubmit(event) {
  event.preventDefault();
  const form = event.target;
  const errorBox = $("#add-error");
  errorBox.textContent = "";
  const payload = Object.fromEntries(new FormData(form));
  payload.interval_seconds = Number(payload.interval_seconds);
  try {
    await api("/monitors", { method: "POST", body: JSON.stringify(payload) });
    $("#add-dialog").close();
    form.reset();
    toast(`Now monitoring ${payload.name}`);
    refresh();
  } catch (e) {
    errorBox.textContent = e.message;               // e.g. SSRF protection: "private ... not allowed"
  }
}

// ---------- refresh loop ----------
async function refresh() {
  try {
    const [summary, monitors, incidents] = await Promise.all([api("/summary"), api("/monitors"), api("/incidents")]);
    renderSummary(summary);
    renderMonitors(monitors);
    renderIncidents(incidents);
    $("#live-indicator").classList.remove("stale");
    const dlg = $("#detail-dialog");
    if (dlg.open && state.openDetailId) openDetail(state.openDetailId);
  } catch (e) {
    $("#live-indicator").classList.add("stale");
    $("#hero-subtitle").textContent = `Can't reach the API right now (${e.message}). Retrying…`;
  }
}

async function loadVersion() {
  try {
    const v = await api("/version");
    $("#pod-name").textContent = v.pod;
    $("#app-version").textContent = v.version;
    state.readOnly = v.read_only;
    applyMode();
  } catch { /* footer info is optional */ }
}

// ---------- read-only demo mode ----------
function applyMode() {
  const admin = !state.readOnly || Boolean(getToken());
  document.body.classList.toggle("read-only", !admin);
  const badge = $("#mode-badge"), lock = $("#lock-btn");
  badge.hidden = !state.readOnly;
  lock.hidden = !state.readOnly;
  badge.textContent = admin ? "Admin" : "Read-only demo";
  badge.className = `badge ${admin ? "admin" : ""}`;
  lock.classList.toggle("unlocked", admin);
  lock.title = admin ? "Admin mode - click to lock" : "Admin: unlock to make changes";
}

function onLockClick() {
  if (getToken()) {                                  // already admin -> lock again
    setToken("");
    applyMode();
    toast("Locked - back to read-only");
    return;
  }
  $("#unlock-error").textContent = "";
  $("#unlock-form").reset();
  $("#unlock-dialog").showModal();
}

async function onUnlockSubmit(event) {
  event.preventDefault();
  const token = new FormData(event.target).get("token").trim();
  setToken(token);
  try {
    await api("/auth/check");
    $("#unlock-dialog").close();
    applyMode();
    toast("Admin mode unlocked");
  } catch {
    setToken("");
    $("#unlock-error").textContent = "Invalid admin token.";
  }
}

// ---------- theme ----------
function initTheme() {
  let saved = null;
  try { saved = localStorage.getItem("theme"); } catch { /* storage may be blocked */ }
  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.dataset.theme = saved || (prefersDark ? "dark" : "light");
  $("#theme-toggle").addEventListener("click", () => {
    const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem("theme", next); } catch { /* ignore */ }
  });
}

// ---------- start ----------
document.addEventListener("DOMContentLoaded", () => {
  initTheme();
  $("#monitor-list").addEventListener("click", onListClick);
  $("#monitor-list").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && e.target.classList.contains("monitor")) openDetail(Number(e.target.dataset.id));
  });
  $("#add-btn").addEventListener("click", () => { $("#add-error").textContent = ""; $("#add-dialog").showModal(); });
  $("#add-form").addEventListener("submit", onAddSubmit);
  $("#report-btn").addEventListener("click", exportReport);
  $("#lock-btn").addEventListener("click", onLockClick);
  $("#unlock-form").addEventListener("submit", onUnlockSubmit);
  document.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => b.closest("dialog").close()));
  $("#detail-dialog").addEventListener("close", () => (state.openDetailId = null));
  refresh();
  loadReports();
  loadVersion();
  state.timer = setInterval(() => { refresh(); loadVersion(); }, REFRESH_MS);
});
