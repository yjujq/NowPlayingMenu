// Watches this frame's <audio>/<video> elements and reports them to the
// background worker; carries out the commands it sends back.
(() => {
  if (window.__nowPlayingBridge) return;
  window.__nowPlayingBridge = true;
  const ids = new WeakMap();
  let next = 1;
  const frameKey = Math.random().toString(36).slice(2, 8);
  const idOf = (el) => {
    if (!ids.has(el)) ids.set(el, frameKey + "-" + next++);
    return ids.get(el);
  };
  const known = new Map(); // id -> element
  const all = () => {
    // Includes elements in open shadow roots one level down is too costly;
    // the document's own plus ones that announced themselves via events.
    for (const el of document.querySelectorAll("video, audio")) known.set(idOf(el), el);
    // A detached element is the player itself on such sites: kept while it
    // has something loaded.
    for (const [id, el] of known) if (!el.isConnected && el.paused && !el.currentSrc && !el.srcObject) known.delete(id);
    return [...known.values()];
  };

  // What main.js says the page handles itself.
  const pageHandles = (action) =>
    ((document.documentElement && document.documentElement.getAttribute("data-npm-actions")) || "").split(" ").includes(action);

  const describe = (el) => {
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    // The cover the page gives; else a video's poster.
    const art = md && md.artwork && md.artwork.length ? md.artwork[md.artwork.length - 1].src
      : (el.poster || "");
    const d = el.duration;
    return {
      id: idOf(el),
      kind: el.tagName.toLowerCase(),
      title: (md && md.title) || document.title || location.hostname,
      artist: (md && md.artist) || "",
      host: location.hostname,
      artwork: art,
      playing: !el.paused && !el.ended,
      muted: el.muted || el.volume === 0,
      time: el.currentTime || 0,
      duration: isFinite(d) ? d : 0,
      // The page has its own next track: the app shows ⏮ ⏭, not ±15 s.
      tracks: pageHandles("nexttrack"),
      at: Date.now(),
    };
  };

  let timer = null;
  const report = (event = false) => {
    timer = null;
    // Like Chrome's own media controls: anything playing, and anything
    // paused that has been started or that the page has loaded and named.
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    const items = all()
      .filter((el) => !el.paused || el.currentTime > 0 || (md && el.readyState > 0))
      .filter((el) => !(el.muted && el.paused && el.currentTime === 0))
      .map(describe);
    try { chrome.runtime.sendMessage({ type: "media", items, event }); } catch (e) { /* extension reloaded */ }
  };
  const soon = () => { if (!timer) timer = setTimeout(() => report(true), 150); };

  const TYPES = ["play", "playing", "pause", "ended", "seeked", "durationchange", "loadedmetadata", "volumechange", "emptied"];
  for (const type of TYPES) {
    document.addEventListener(type, (e) => {
      if (e.target instanceof HTMLMediaElement) { known.set(idOf(e.target), e.target); soon(); }
    }, true);
  }
  // Media outside the document, announced by main.js: its events go to the
  // element alone, so they are listened for on it.
  const watched = new WeakSet();
  document.addEventListener("__nowplaying_media", (e) => {
    let el = e.relatedTarget;
    if (!(el instanceof HTMLMediaElement)) {
      const id = document.documentElement.getAttribute("data-npm-last");
      el = el && el.shadowRoot ? el.shadowRoot.querySelector(`[data-npm-id="${id}"]`) : null;
    }
    if (!(el instanceof HTMLMediaElement)) return;
    known.set(idOf(el), el);
    if (!watched.has(el)) { watched.add(el); for (const t of TYPES) el.addEventListener(t, soon); }
    soon();
  });
  // Position moves on its own; a slow heartbeat while something plays.
  // Paused ones too, so a restarted background worker learns them again.
  setInterval(() => report(false), 3000);
  window.addEventListener("pagehide", () => {
    try { chrome.runtime.sendMessage({ type: "media", items: [] }); } catch (e) {}
  });
  soon();

  const press = (action, value) => {
    if (!pageHandles(action)) return false;
    document.dispatchEvent(new CustomEvent("__nowplaying_cmd", { detail: JSON.stringify({ action, value }) }));
    return true;
  };

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type !== "command") return;
    const el = known.get(msg.id);
    if (!el) return;
    const v = Number(msg.value || 0);
    // Of a tab's media only the one the page is playing is its player; its
    // buttons go through the page's handlers first, as Chrome's do.
    const playElement = () => el.play().catch(() => press("play"));
    if (msg.action === "toggle") {
      if (el.paused) { if (!press("play")) playElement(); }
      else if (!press("pause")) el.pause();
    } else if (msg.action === "play") { if (!press("play")) playElement(); }
    else if (msg.action === "pause") { if (!press("pause")) el.pause(); }
    else if (msg.action === "next") { if (!press("nexttrack")) el.currentTime = Math.min(el.duration || 1e9, el.currentTime + 15); }
    else if (msg.action === "previous") { if (!press("previoustrack")) el.currentTime = Math.max(0, el.currentTime - 15); }
    else if (msg.action === "skip") {
      if (!press(v >= 0 ? "seekforward" : "seekbackward", v) && !press("seekto", Math.max(0, el.currentTime + v)))
        el.currentTime = Math.max(0, el.currentTime + v);
    } else if (msg.action === "seek") { if (!press("seekto", v)) el.currentTime = v; }
    // The page's handler may take a moment: report once it has.
    soon(); setTimeout(soon, 400); setTimeout(soon, 1200);
  });
})();
