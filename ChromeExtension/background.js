// Collects every frame's media and posts the whole list to the app on
// 127.0.0.1:47811; the reply holds commands for the tabs.
const APP = "http://127.0.0.1:47811/state";
// key "tabId:frameId" -> items
const frames = new Map();
// Tells this Chrome profile apart from others posting to the same app.
const INSTANCE = crypto.randomUUID();
let posting = false, again = false;

// One entry per tab, as in Chrome's own media controls: of a tab's media
// (previews, ads, embeds) the one playing, else the one with named
// metadata, else the longest-run one.
function list() {
  const best = new Map();
  const score = (it) => (it.playing ? 4 : 0) + (it.artist ? 2 : 0) + (it.frameId === 0 ? 1 : 0);
  for (const [key, items] of frames) {
    const [tabId, frameId] = key.split(":").map(Number);
    for (const it of items) {
      const entry = { ...it, tabId, frameId, id: `${tabId}:${frameId}:${it.id}` };
      const cur = best.get(tabId);
      if (!cur || score(entry) > score(cur) || (score(entry) === score(cur) && entry.time > cur.time)) best.set(tabId, entry);
    }
  }
  return [...best.values()];
}

// What was last sent, without the position: that moves on its own and the
// app counts it out from the last reading.
let sentSignature = "", sentAt = 0;
const signature = (items) => JSON.stringify(items.map(({ time, at, ...rest }) => rest));

async function post(force = false) {
  if (posting) { again = true; return; }
  posting = true;
  try {
    const items = list();
    // Unchanged, and sent lately: nothing to say.
    const sig = signature(items);
    if (!force && sig === sentSignature && Date.now() - sentAt < 4000) { posting = false; return; }
    // Tab titles from Chrome itself are better than an iframe's document.title.
    for (const it of items) {
      if (it.frameId !== 0 && !it.artist) {
        try { const t = await chrome.tabs.get(it.tabId); it.title = t.title || it.title; it.host = new URL(t.url).hostname; } catch (e) {}
      }
    }
    for (const it of items) it.favicon = await favicon(it.tabId);
    const r = await fetch(APP, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ instance: INSTANCE, items }) });
    const { commands = [] } = await r.json();
    sentSignature = sig; sentAt = Date.now();
    for (const c of commands) run(c);
    wait();
  } catch (e) { /* app not running */ }
  posting = false;
  if (again) { again = false; post(); }
}

// Each site's icon from Chrome's own cache, as a data: URL — no request
// leaves the computer. Kept by host; Chrome draws a grey globe for a site
// with none, which is sent all the same.
const icons = new Map();
async function favicon(tabId) {
  try {
    const t = await chrome.tabs.get(tabId);
    const host = new URL(t.url).host;
    if (icons.has(host)) return icons.get(host);
    const u = new URL(chrome.runtime.getURL("/_favicon/"));
    u.searchParams.set("pageUrl", t.url);
    u.searchParams.set("size", "64");
    const blob = await (await fetch(u)).blob();
    const data = await new Promise((res) => { const fr = new FileReader(); fr.onload = () => res(fr.result); fr.readAsDataURL(blob); });
    icons.set(host, data);
    return data;
  } catch (e) { return ""; }
}

async function run(c) {
  const [tabId, frameId, ...rest] = c.id.split(":");
  const tab = Number(tabId);
  if (c.action === "focus") {
    try { const t = await chrome.tabs.update(tab, { active: true }); await chrome.windows.update(t.windowId, { focused: true }); } catch (e) {}
    return;
  }
  chrome.tabs.sendMessage(tab, { type: "command", id: rest.join(":"), action: c.action, value: c.value },
    { frameId: Number(frameId) }).catch(() => {});
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (msg.type !== "media" || !sender.tab) return;
  const key = `${sender.tab.id}:${sender.frameId}`;
  if (msg.items.length) frames.set(key, msg.items); else frames.delete(key);
  // An event (play, pause, seek) says so; a heartbeat does not force a post.
  post(msg.event === true);
});
chrome.tabs.onRemoved.addListener((tabId) => {
  for (const k of [...frames.keys()]) if (k.startsWith(tabId + ":")) frames.delete(k);
  post();
});
chrome.tabs.onUpdated.addListener((tabId, info) => {
  if (info.status === "loading") { for (const k of [...frames.keys()]) if (k.startsWith(tabId + ":")) frames.delete(k); post(); }
});

// Post each second so commands from the app arrive quickly and the app
// knows the extension is there; the alarm wakes a worker Chrome put to sleep.
// Commands from the app: one request held open, answered when there is one.
let waitingNow = false;
async function wait() {
  if (waitingNow) return;
  waitingNow = true;
  try {
    while (frames.size) {
      const r = await fetch(`http://127.0.0.1:47811/wait?instance=${INSTANCE}`);
      // Turned away: not asked again at once, round and round.
      if (!r.ok) { await new Promise((res) => setTimeout(res, 5000)); continue; }
      const { commands = [] } = await r.json();
      for (const c of commands) run(c);
    }
  } catch (e) { /* app gone; the next post starts it again */ }
  waitingNow = false;
}

// A keepalive: the app counts a list as current for 12 seconds.
setInterval(() => post(), 4000);

// Tabs opened before the extension was installed or reloaded have no
// content script: put one into each, so their paused media is listed too.
async function injectAll() {
  for (const t of await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] })) {
    chrome.scripting.executeScript({ target: { tabId: t.id, allFrames: true }, files: ["content.js"] }).catch(() => {});
    chrome.scripting.executeScript({ target: { tabId: t.id, allFrames: true }, files: ["main.js"], world: "MAIN" }).catch(() => {});
  }
}
chrome.runtime.onInstalled.addListener(injectAll);
chrome.runtime.onStartup.addListener(injectAll);
injectAll();
chrome.alarms.create("keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => post());
post();
