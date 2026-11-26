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
  const detachedPause = new WeakMap(); // element -> when it was first seen detached and paused
  const all = () => {
    // Includes elements in open shadow roots one level down is too costly;
    // the document's own plus ones that announced themselves via events.
    for (const el of document.querySelectorAll("video, audio")) known.set(idOf(el), el);
    // A detached element is the player itself on such sites: kept while it
    // has something loaded.
    // A detached one paused for ten minutes is let go too.
    for (const [id, el] of known) {
      if (el.isConnected || !el.paused) { detachedPause.delete(el); continue; }
      if (!el.currentSrc && !el.srcObject) { known.delete(id); continue; }
      if (!detachedPause.has(el)) detachedPause.set(el, Date.now());
      else if (Date.now() - detachedPause.get(el) > 600000) known.delete(id);
    }
    return [...known.values()];
  };

  // What main.js says the page handles itself.
  const pageHandles = (action) =>
    ((document.documentElement && document.documentElement.getAttribute("data-npm-actions")) || "").split(" ").includes(action);


  // What the video plays, as the site or its author says: the site's own
  // label of the sound (TikTok's /music/, Instagram's /reels/audio/),
  // YouTube's Music section, else a line of the description — "🎵 Artist -
  // Song", "Track: …" — and its hashtags. Looked for around the element
  // playing first, so that in a feed it is the post being watched.
  var musicInfo = function (el) {
    var clean = function (s) { return (s || "").replace(/\s+/g, " ").trim(); };
    var near = function (selector) {
      var node = el;
      for (var depth = 0; node && depth < 16; depth++) {
        var found = node.querySelector ? node.querySelector(selector) : null;
        if (found) return found;
        node = node.parentElement || (node.getRootNode && node.getRootNode() !== node ? node.getRootNode().host : null);
      }
      return document.querySelector(selector);
    };
    var split = function (text, artistFirst) {
      var m = text.match(/^(.+?)\s+[-–—·]\s+(.+)$/);
      if (!m) return { title: text, artist: "" };
      return artistFirst ? { title: m[2], artist: m[1] } : { title: m[1], artist: m[2] };
    };
    var result = null;
    var label = near('[data-e2e="browse-music"] a, [data-e2e="video-music"] a, a[href*="/music/"], a[href*="/reels/audio/"], a[href*="/audio/"]');
    // The label's own words: the innermost piece with the separator in it.
    // Instagram adds "Audio image" (the icon's name) and, as the line runs
    // along, a second copy of its start.
    var text = "";
    if (label) {
      var pieces = label.querySelectorAll("span, div");
      for (var k = 0; k < pieces.length && !text; k++) {
        var piece = pieces[k];
        if (piece.children.length === 0 && / [·\-–—] /.test(piece.textContent)) text = clean(piece.textContent);
      }
      if (!text) text = clean(label.textContent.replace(/^(Audio image|Аудио)/i, ""));
    }
    if (text) {
      // Instagram: "Artist · Song"; TikTok: "Song - Artist".
      result = split(text, text.indexOf(" · ") > 0);
      result.url = label.href;
    }
    if (!result) {
      var yt = document.querySelector("yt-video-attribute-view-model, ytd-video-attribute-view-model");
      var t = yt && yt.querySelector('[class*="__title"]');
      if (t && clean(t.textContent)) {
        var s = yt.querySelector('[class*="__subtitle"]');
        result = { title: clean(t.textContent), artist: clean(s && s.textContent), url: "" };
      }
    }
    var desc = near('[data-e2e="browse-video-desc"], [data-e2e="video-desc"], #description-inline-expander, ytd-text-inline-expander, #description, h1, [class*="caption" i], [class*="description" i]');
    // innerText keeps the description's line breaks; it costs a layout, so
    // this runs only when the cache above runs out.
    var body = desc ? (desc.innerText || desc.textContent || "") : "";
    if (!result && body) {
      var lines = body.split(/\n/);
      for (var i = 0; i < lines.length && !result; i++) {
        var m = lines[i].length > 300 ? null : lines[i].match(/(?:🎵|🎶|♪|♫|🎧|🎤)️?\s*[:：]?\s*(.{2,90})|(?:song|track|music|sound|audio|трек|песня|музыка|звук|саундтрек)\s*[:：]\s*(.{2,90})/i);
        if (m) {
          var value = clean((m[1] || m[2]).replace(/#\S+/g, ""));
          if (value) { result = split(value, true); result.url = ""; }
        }
      }
    }
    var tags = (body.match(/#[^\s#.,!?;:]+/g) || []).slice(0, 6);
    if (!result && !tags.length) return null;
    result = result || { title: "", artist: "", url: "" };
    result.tags = tags;
    return result;
  };
  // The track is looked for again only every 15 s, or when the element or
  // the address changes: reading the description walks a good part of a
  // feed's page.
  const musicCache = new WeakMap(); // element -> { at, href, value }
  const music = (el) => {
    if (window !== window.top) return null;
    const cached = musicCache.get(el);
    if (cached && cached.href === location.href && Date.now() - cached.at < 15000) return cached.value;
    let value = null;
    try { value = musicInfo(el); } catch (e) {}
    musicCache.set(el, { at: Date.now(), href: location.href, value });
    return value;
  };

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
      music: music(el),
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
    // Nothing now and nothing last time: the worker knows; it is not woken.
    if (!items.length && sentEmpty) return;
    sentEmpty = !items.length;
    try { chrome.runtime.sendMessage({ type: "media", items, event }); } catch (e) { /* extension reloaded */ }
  };
  let sentEmpty = false;
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
  // Left behind by a reloaded extension, it stops.
  const heartbeat = setInterval(() => {
    if (!chrome.runtime || !chrome.runtime.id) { clearInterval(heartbeat); return; }
    report(false);
  }, 3000);
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
