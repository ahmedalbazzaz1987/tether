"use strict";
const $ = (id) => document.getElementById(id);
const token = location.hash.slice(1);
let ws = null, S = null, lastScreen = "";
let unreadChat = 0, drawerOpen = false;

function send(o) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)); }

function connectWS() {
  ws = new WebSocket(`ws://${location.host}/ws?token=${token}`);
  ws.binaryType = "arraybuffer";
  ws.onmessage = (e) => {
    if (typeof e.data !== "string") { onVideo(e.data); return; }
    const m = JSON.parse(e.data);
    switch (m.ev) {
      case "state": S = m; render(); break;
      case "chat": if (m.remote && !drawerOpen && S && S.view.state === "connected") { unreadChat++; renderBadge(); } break;
      case "file": fileMap.set((m.file.incoming ? "i" : "o") + m.file.id, m.file); renderPanels(); break;
      case "ping": if ($("vPing")) $("vPing").textContent = m.ms + " ms"; break;
      case "toast": toast(m.text); break;
      case "ended": resetVideo(); break;
    }
  };
  ws.onclose = () => setTimeout(connectWS, 800);
}

function toast(t) {
  const el = $("toast"); el.textContent = t; el.classList.remove("hidden");
  clearTimeout(toast._t); toast._t = setTimeout(() => el.classList.add("hidden"), 3200);
}

function show(id) {
  for (const s of ["home", "hosting", "viewer"]) $(s).classList.toggle("hidden", s !== id);
}

function esc(s) { return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function fmtSize(n) { if (n < 1024) return n + " B"; if (n < 1048576) return (n / 1024).toFixed(0) + " KB"; if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB"; return (n / 1073741824).toFixed(2) + " GB"; }
function fmtTarget(t) { return /^\d{9}$/.test(t) ? t.replace(/(\d{3})(\d{3})(\d{3})/, "$1 $2 $3") : t; }

// ---------------- rendering ----------------
function render() {
  if (!S) return;
  const screen = S.view.state === "connected" ? "viewer" : S.host ? "hosting" : "home";
  if (screen !== lastScreen) {
    show(screen);
    if (screen !== "home") fileMap.clear();
    if (screen === "viewer") { resetVideo(); setTimeout(() => $("screen").focus(), 50); }
    if (lastScreen === "viewer") { setFull(false); drawerOpen = false; $("drawer").classList.add("hidden"); releaseAll(); }
    lastScreen = screen;
  }
  // home
  $("myId").textContent = S.idFmt;
  $("myOtp").textContent = S.otp;
  const st = $("hostStatus");
  st.classList.toggle("ok", S.relayOnline || (!S.relayUrl && S.lanActive));
  st.classList.toggle("off", !S.acceptIncoming);
  let txt = S.relayStatus;
  if (!S.relayOnline && S.lanActive && S.acceptIncoming) txt += S.relayUrl ? " · local network ready" : "";
  if (!S.relayUrl && S.lanActive && S.acceptIncoming) txt = "Local network ready" + ((S.lanIPs || []).length ? " (" + S.lanIPs.join(", ") + ")" : "");
  $("hostStatusText").textContent = txt;

  const v = S.view;
  const connecting = v.state === "connecting";
  $("btnConnect").disabled = connecting;
  $("btnConnect").textContent = connecting ? "Connecting…" : "Connect";
  $("btnCancel").classList.toggle("hidden", !connecting);
  $("connectError").classList.toggle("hidden", !v.error || v.keyChanged);
  $("connectError").textContent = v.error || "";
  $("keyWarn").classList.toggle("hidden", !v.keyChanged);
  $("keyWarnText").textContent = v.error || "";

  const rec = $("recent");
  if (!S.recent || !S.recent.length) rec.innerHTML = '<div class="empty">No recent connections</div>';
  else rec.innerHTML = S.recent.map(r => `
    <div class="recent-item" data-target="${esc(r.target)}">
      <div class="os">${r.os === "mac" ? "Mac" : "Win"}</div>
      <div class="meta"><div class="name">${esc(r.name || fmtTarget(r.target))}</div><div class="sub mono">${esc(fmtTarget(r.target))}</div></div>
      <button class="icon-btn x" data-remove="${esc(r.target)}" title="Remove">✕</button>
    </div>`).join("");

  const ub = $("updateBar");
  ub.classList.toggle("hidden", !S.update);
  if (S.update) { $("updateText").textContent = S.updBusy ? S.updMsg : `Tether ${S.update.version} is available.`; $("btnUpdateNow").disabled = S.updBusy; }

  // hosting
  if (S.host) {
    $("hostViewer").textContent = S.host.viewer || "Someone";
    $("hostKind").textContent = S.host.kind === "direct" ? "Direct connection on your local network · end-to-end encrypted" : "Connected through your relay · end-to-end encrypted";
  }
  // viewer
  if (v.state === "connected") {
    $("vName").textContent = v.remoteName || fmtTarget(v.target);
    const k = $("vKind"); k.textContent = v.kind === "direct" ? "Direct" : "Relay"; k.classList.toggle("direct", v.kind === "direct");
    const ds = $("vDisplay");
    const opts = (v.displays || []).map(d => `<option value="${d.id}">${esc(d.name)} (${d.w}×${d.h})</option>`).join("");
    if (ds.dataset.opts !== opts) { ds.innerHTML = opts; ds.dataset.opts = opts; }
    ds.value = String(v.display); ds.classList.toggle("hidden", (v.displays || []).length < 2);
    $("vQuality").value = S.quality || "balanced";
    if (swapPref === null) $("chkSwap").checked = v.remoteOS === "mac";
  }
  renderPanels();
  renderSettings();
}

function renderBadge() {
  const b = $("chatBadge"); b.textContent = unreadChat; b.classList.toggle("hidden", unreadChat === 0);
}

// chat & files panels (one in the hosting screen, one in the viewer drawer)
function ensurePanel(container) {
  if (container.firstChild) return container.firstChild;
  const p = $("panelTpl").content.firstElementChild.cloneNode(true);
  p.querySelectorAll(".tab").forEach(t => t.onclick = () => {
    p.querySelectorAll(".tab").forEach(x => x.classList.toggle("active", x === t));
    p.querySelector(".chat-body").classList.toggle("hidden", t.dataset.tab !== "chat");
    p.querySelector(".files-body").classList.toggle("hidden", t.dataset.tab !== "files");
  });
  p.querySelector(".chat-form").onsubmit = (e) => {
    e.preventDefault(); const i = p.querySelector(".chat-in");
    if (i.value.trim()) send({ cmd: "chat", text: i.value }); i.value = "";
  };
  p.querySelector(".btn-send-file").onclick = () => send({ cmd: "sendFile" });
  p.querySelector(".btn-open-dl").onclick = () => send({ cmd: "openDownloads" });
  container.appendChild(p);
  return p;
}
const fileMap = new Map();
function renderPanels() {
  if (!S) return;
  for (const c of [$("hostPanel"), $("drawer")]) {
    const p = ensurePanel(c);
    const log = p.querySelector(".chat-log");
    const html = (S.chat || []).map(m => `<div class="msg ${m.remote ? "" : "me"}">${esc(m.text)}</div>`).join("");
    if (log.dataset.h !== html) { log.innerHTML = html || '<div class="empty">Messages are end-to-end encrypted.</div>'; log.dataset.h = html; log.scrollTop = 1e9; }
    const fl = p.querySelector(".file-list");
    for (const f of S.files || []) { const k = (f.incoming ? "i" : "o") + f.id; const old = fileMap.get(k); if (!old || old.state === "active") fileMap.set(k, f); }
    const files = [...fileMap.values()].slice(-30).reverse();
    fl.innerHTML = files.length ? files.map(f => {
      const pct = f.size ? Math.round(f.done / f.size * 100) : 100;
      const dir = f.incoming ? "Received" : "Sent";
      const stateTxt = f.state === "active" ? `${fmtSize(f.done)} of ${fmtSize(f.size)}` : f.state === "done" ? `${dir} · ${fmtSize(f.size)}` : "Failed";
      const open = f.incoming && f.state === "done" && f.path ? `<span class="link" data-open="${esc(f.path)}">Open</span>` : "";
      return `<div class="file ${f.state}"><div class="top"><span class="fname">${f.incoming ? "↓" : "↑"} ${esc(f.name)}</span>${open}</div><div class="fsub">${stateTxt}</div><div class="bar"><i style="width:${pct}%"></i></div></div>`;
    }).join("") : '<div class="empty">No transfers yet</div>';
  }
}

let settingsDirty = false;
function renderSettings() {
  if (!S || settingsDirty) return;
  if (document.activeElement !== $("setRelay")) $("setRelay").value = S.relayUrl || "";
  $("setAccept").checked = S.acceptIncoming;
  $("setLan").checked = S.allowLan;
  $("lanInfo").textContent = S.lanError ? "Local network listener failed: " + S.lanError :
    S.lanActive ? `Listening on ${(S.lanIPs || []).map(i => i + ":" + S.lanPort).join(", ") || "port " + S.lanPort}` : "";
  $("setLogin").checked = S.launchAtLogin;
  $("setClip").checked = S.clipboardSync;
  $("setAutoUpd").checked = S.autoUpdate;
  $("permState").textContent = S.hasPermPassword ? "A permanent password is set. This computer can be reached any time Tether is running." : "No permanent password. Only the one-time password works.";
  $("fp").textContent = S.fingerprint;
  $("ver").textContent = S.version;
  $("updMsg").textContent = S.updMsg || "";
  $("dlPath").textContent = S.downloads;
}

// ---------------- video ----------------
const canvas = $("screen");
const ctx2d = canvas.getContext("2d", { alpha: false, desynchronized: true });
let queue = [], busy = false, gotFrame = false, remoteW = 0, remoteH = 0, fitMode = true;

function resetVideo() {
  queue = []; gotFrame = false; $("stageMsg").classList.remove("hidden");
  $("stageMsg").textContent = "Waiting for the first picture…";
}
function onVideo(buf) { queue.push(buf); if (!busy) pump(); }
async function pump() {
  busy = true;
  while (queue.length) {
    const buf = queue.shift();
    try { await drawFrame(buf); } catch (e) { console.error(e); }
  }
  busy = false;
}
async function drawFrame(buf) {
  const dv = new DataView(buf);
  const seq = dv.getUint32(0), w = dv.getUint16(4), h = dv.getUint16(6), n = dv.getUint16(8);
  if (w !== remoteW || h !== remoteH) { remoteW = w; remoteH = h; canvas.width = w; canvas.height = h; layout(); }
  let off = 10; const jobs = [];
  for (let i = 0; i < n; i++) {
    const x = dv.getUint16(off), y = dv.getUint16(off + 2), len = dv.getUint32(off + 9);
    const blob = new Blob([new Uint8Array(buf, off + 13, len)], { type: "image/jpeg" });
    jobs.push(createImageBitmap(blob).then(b => ({ x, y, b })));
    off += 13 + len;
  }
  const bitmaps = await Promise.all(jobs);
  for (const { x, y, b } of bitmaps) { ctx2d.drawImage(b, x, y); b.close(); }
  send({ cmd: "ack", seq });
  if (!gotFrame) { gotFrame = true; $("stageMsg").classList.add("hidden"); }
}
function layout() {
  const stage = $("stage");
  stage.classList.toggle("actual", !fitMode);
  if (fitMode) { canvas.style.width = ""; canvas.style.height = ""; }
  else { canvas.style.width = (remoteW / devicePixelRatio) + "px"; canvas.style.height = (remoteH / devicePixelRatio) + "px"; }
  $("btnFit").textContent = fitMode ? "Fit" : "1:1";
}

// ---------------- input ----------------
function norm(e) {
  const r = canvas.getBoundingClientRect();
  const x = Math.round(Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1) * 65535);
  const y = Math.round(Math.min(Math.max((e.clientY - r.top) / r.height, 0), 1) * 65535);
  return { x, y };
}
const btnMap = { 0: 0, 1: 2, 2: 1 };
let lastMove = 0, pendingMove = null;
canvas.addEventListener("mousemove", (e) => {
  const p = norm(e); pendingMove = p;
  const now = performance.now();
  if (now - lastMove > 12) { lastMove = now; send({ cmd: "mouse", k: 0, x: p.x, y: p.y }); pendingMove = null; }
  else if (!mm._t) mm._t = setTimeout(mm, 14);
});
function mm() { mm._t = null; if (pendingMove) { send({ cmd: "mouse", k: 0, x: pendingMove.x, y: pendingMove.y }); pendingMove = null; lastMove = performance.now(); } }
const downButtons = new Set();
canvas.addEventListener("mousedown", (e) => { canvas.focus(); downButtons.add(e.button); const p = norm(e); send({ cmd: "mouse", k: 1, b: btnMap[e.button] ?? 0, x: p.x, y: p.y }); e.preventDefault(); });
window.addEventListener("mouseup", (e) => { if (lastScreen !== "viewer" || !downButtons.delete(e.button)) return; const p = norm(e); send({ cmd: "mouse", k: 2, b: btnMap[e.button] ?? 0, x: p.x, y: p.y }); });
canvas.addEventListener("contextmenu", (e) => e.preventDefault());
canvas.addEventListener("wheel", (e) => {
  e.preventDefault();
  const f = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? 400 : 1;
  const p = norm(e);
  send({ cmd: "mouse", k: 3, x: p.x, y: p.y, dx: Math.round(e.deltaX * f * 1.2), dy: Math.round(-e.deltaY * f * 1.2) });
}, { passive: false });

const HID = (() => {
  const m = {};
  for (let i = 0; i < 26; i++) m["Key" + String.fromCharCode(65 + i)] = 4 + i;
  for (let i = 1; i <= 9; i++) m["Digit" + i] = 29 + i;
  m.Digit0 = 39;
  Object.assign(m, { Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, Minus: 45, Equal: 46, BracketLeft: 47, BracketRight: 48,
    Backslash: 49, Semicolon: 51, Quote: 52, Backquote: 53, Comma: 54, Period: 55, Slash: 56, CapsLock: 57,
    PrintScreen: 70, ScrollLock: 71, Pause: 72, Insert: 73, Home: 74, PageUp: 75, Delete: 76, End: 77, PageDown: 78,
    ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82, NumLock: 83, NumpadDivide: 84, NumpadMultiply: 85,
    NumpadSubtract: 86, NumpadAdd: 87, NumpadEnter: 88, Numpad0: 98, NumpadDecimal: 99, IntlBackslash: 100,
    ContextMenu: 101, NumpadEqual: 103, ControlLeft: 224, ShiftLeft: 225, AltLeft: 226, MetaLeft: 227,
    ControlRight: 228, ShiftRight: 229, AltRight: 230, MetaRight: 231, AudioVolumeMute: 127, AudioVolumeUp: 128, AudioVolumeDown: 129 });
  for (let i = 1; i <= 12; i++) m["F" + i] = 57 + i;
  for (let i = 13; i <= 24; i++) m["F" + i] = 91 + i;
  for (let i = 1; i <= 9; i++) m["Numpad" + i] = 88 + i;
  return m;
})();
let swapPref = null;
const pressed = new Set();
function mapKey(code) {
  let h = HID[code]; if (!h) return 0;
  if ($("chkSwap").checked) { if (h === 224) h = 227; else if (h === 227) h = 224; else if (h === 228) h = 231; else if (h === 231) h = 228; }
  return h;
}
function keyActive(e) {
  if (lastScreen !== "viewer") return false;
  const t = e.target; if (t && (t.tagName === "INPUT" || t.tagName === "SELECT" || t.tagName === "TEXTAREA")) return false;
  return true;
}
window.addEventListener("keydown", (e) => {
  if (e.code === "F11" && lastScreen === "viewer") { e.preventDefault(); setFull(!document.body.classList.contains("full")); return; }
  if (!keyActive(e)) return;
  const h = mapKey(e.code); if (!h) return;
  e.preventDefault(); pressed.add(h); send({ cmd: "key", d: true, h });
});
window.addEventListener("keyup", (e) => {
  if (!keyActive(e)) return;
  const h = mapKey(e.code); if (!h) return;
  e.preventDefault(); pressed.delete(h); send({ cmd: "key", d: false, h });
});
function releaseAll() { for (const h of pressed) send({ cmd: "key", d: false, h }); pressed.clear(); }
window.addEventListener("blur", releaseAll);

// ---------------- viewer toolbar ----------------
function setFull(on) {
  document.body.classList.toggle("full", on);
  send({ cmd: "fullscreen", d: on });
}
document.addEventListener("mousemove", (e) => {
  if (!document.body.classList.contains("full")) return;
  $("vbar").classList.toggle("show", e.clientY < 8 || (e.clientY < 48 && $("vbar").classList.contains("show")));
});
$("btnFull").onclick = () => setFull(!document.body.classList.contains("full"));
$("btnFit").onclick = () => { fitMode = !fitMode; layout(); };
$("vDisplay").onchange = (e) => send({ cmd: "display", id: +e.target.value });
$("vQuality").onchange = (e) => send({ cmd: "quality", q: e.target.value });
$("btnDisconnect").onclick = () => send({ cmd: "disconnect" });
$("btnChat").onclick = () => { drawerOpen = !drawerOpen; $("drawer").classList.toggle("hidden", !drawerOpen); if (drawerOpen) { unreadChat = 0; renderBadge(); } };
$("btnKeys").onclick = (e) => { e.stopPropagation(); $("keysMenu").classList.toggle("hidden"); };
document.addEventListener("click", (e) => { if (!e.target.closest(".menu")) $("keysMenu").classList.add("hidden"); });
$("keysMenu").querySelectorAll("[data-combo]").forEach(b => b.onclick = () => {
  send({ cmd: "combo", keys: b.dataset.combo.split(",").map(Number) }); $("keysMenu").classList.add("hidden"); canvas.focus();
});
$("chkSwap").onchange = () => { swapPref = $("chkSwap").checked; };

// ---------------- home actions ----------------
$("connectForm").onsubmit = (e) => {
  e.preventDefault();
  const target = $("inTarget").value.trim(); if (!target) { $("inTarget").focus(); return; }
  send({ cmd: "connect", target, password: $("inPassword").value });
};
$("btnCancel").onclick = () => send({ cmd: "cancelConnect" });
$("btnTrustNew").onclick = () => send({ cmd: "forgetHost", target: S.view.target });
$("inTarget").addEventListener("input", () => { if (S && S.view.error) send({ cmd: "clearError" }); });
$("recent").onclick = (e) => {
  const rm = e.target.closest("[data-remove]");
  if (rm) { e.stopPropagation(); send({ cmd: "removeRecent", target: rm.dataset.remove }); return; }
  const it = e.target.closest(".recent-item");
  if (it) { $("inTarget").value = fmtTarget(it.dataset.target); $("inPassword").value = ""; $("inPassword").focus(); }
};
$("btnNewOtp").onclick = () => send({ cmd: "newOtp" });
document.querySelectorAll("[data-copy]").forEach(b => b.onclick = () => {
  const v = b.dataset.copy === "id" ? S.id : S.otp;
  navigator.clipboard.writeText(v).then(() => toast("Copied"), () => toast(v));
});
$("btnEndHost").onclick = () => send({ cmd: "endHost" });
$("btnUpdateNow").onclick = () => send({ cmd: "applyUpdate" });
document.addEventListener("click", (e) => { const o = e.target.closest("[data-open]"); if (o) send({ cmd: "openPath", text: o.dataset.open }); });

// ---------------- settings ----------------
$("btnSettings").onclick = () => { $("settings").classList.remove("hidden"); renderSettings(); };
$("btnCloseSettings").onclick = () => { saveRelay(); $("settings").classList.add("hidden"); };
$("settings").onclick = (e) => { if (e.target === $("settings")) { saveRelay(); $("settings").classList.add("hidden"); } };
function saveRelay() { if (S && $("setRelay").value.trim() !== (S.relayUrl || "")) send({ cmd: "settings", settings: { relayUrl: $("setRelay").value.trim() } }); }
$("setRelay").addEventListener("change", saveRelay);
const bind = (id, key) => $(id).onchange = (e) => send({ cmd: "settings", settings: { [key]: e.target.checked } });
bind("setAccept", "acceptIncoming"); bind("setLan", "allowLan"); bind("setLogin", "launchAtLogin");
bind("setClip", "clipboardSync"); bind("setAutoUpd", "autoUpdate");
$("btnSetPerm").onclick = () => { send({ cmd: "setPermPassword", password: $("setPerm").value }); $("setPerm").value = ""; };
$("btnClearPerm").onclick = () => send({ cmd: "clearPermPassword" });
$("btnOpenDl").onclick = () => send({ cmd: "openDownloads" });
$("btnCheckUpd").onclick = () => send({ cmd: "checkUpdate" });
$("btnQuit").onclick = () => send({ cmd: "quit" });
$("btnUninstall").onclick = () => {
  $("confirmText").textContent = "Remove Tether and all of its settings from this computer? Active sessions will end. Files you received are kept.";
  $("confirm").classList.remove("hidden");
};
$("confirmNo").onclick = () => $("confirm").classList.add("hidden");
$("confirmYes").onclick = () => { $("confirm").classList.add("hidden"); send({ cmd: "uninstall" }); };

connectWS();
