// Reads the media in every Safari and Chrome tab, or acts on one tab's.
//
// The system sees one player per browser, whichever tab last played; the
// page itself sees all of its own. So each tab is asked through the
// browser's scripting — `do JavaScript` in Safari, `execute` in Chrome —
// which needs "Allow JavaScript from Apple Events" switched on in each.
//
//   osascript -l JavaScript browser-tabs.js list BROWSER SKIP
//       → one JSON line per tab as it is read — {"start": ID} before
//         asking it, {"tab": {...}} if it has media — and {"blocked": true}
//         if the browser refuses. Written as it goes, so that if a tab never
//         answers (Chrome's asleep ones do not) and the reading is cut off,
//         what was read is kept and the last "start" names the tab to skip,
//         one of the comma-separated SKIP ids, from then on.
//   osascript -l JavaScript browser-tabs.js command BROWSER WINDOW TAB ACTION VALUE
//       ACTION is toggle, skip (VALUE seconds, either way), seek (VALUE), or
//       focus — show that tab, in front.

// The page's own media: the element playing, or one that has played and is
// paused. Muted ones are left out — a silent looping banner is not a player.
// A page that plays from an element it never puts in the document —
// SoundCloud does — is found by the Now Playing details it gives the
// browser instead, without a position, and played or paused with its own
// button ("controls": "button").
const READ = `(function () {
  var all = Array.prototype.slice.call(document.querySelectorAll("video, audio"));
  var live = all.filter(function (e) { return !e.muted && e.volume > 0 && (e.currentTime > 0 || !e.paused); });
  var session = navigator.mediaSession;
  var md = session && session.metadata;
  if (!live.length && !md) return "";
  // A page that says what it plays but has not started it yet: its element.
  var waiting = all.filter(function (x) { return !x.muted; });
  var e = live.filter(function (x) { return !x.paused; })[0] || live[0] || (md ? waiting[0] : null);
  var art = md && md.artwork && md.artwork.length ? md.artwork[md.artwork.length - 1].src : "";
  return JSON.stringify({
    title: (md && md.title) || document.title,
    artist: (md && md.artist) || "",
    host: location.hostname,
    artwork: art,
    playing: e ? !e.paused : session.playbackState === "playing",
    time: e ? e.currentTime : 0,
    duration: e && isFinite(e.duration) ? e.duration : 0,
    controls: e ? "element" : "button"
  });
})()`;

function act(action, value) {
  return `(function (a, v) {
  var all = Array.prototype.slice.call(document.querySelectorAll("video, audio"));
  var live = all.filter(function (e) { return !e.muted && e.volume > 0 && (e.currentTime > 0 || !e.paused); });
  var md = navigator.mediaSession && navigator.mediaSession.metadata;
  var waiting = all.filter(function (x) { return !x.muted; });
  var e = live.filter(function (x) { return !x.paused; })[0] || live[0] || (md ? waiting[0] : null);
  if (!e) {
    // No element in the page: its own play or pause button, as the sites
    // that play this way name theirs.
    if (a !== "toggle") return "";
    var button = document.querySelector([
      ".playControl",                                   // SoundCloud
      "[data-testid=control-button-playpause]",         // Spotify
      "#play-pause-button",                             // YouTube Music
      "button[aria-label=Pause]", "button[aria-label=Play]",
      "button[title=Pause]", "button[title=Play]"
    ].join(","));
    if (!button) return "";
    button.click();
    return "ok";
  }
  if (a === "toggle") { if (e.paused) e.play(); else e.pause(); }
  else if (a === "skip") e.currentTime = Math.max(0, e.currentTime + v);
  else if (a === "seek") e.currentTime = Math.max(0, v);
  return "ok";
})(${JSON.stringify(action)}, ${Number(value) || 0})`;
}

const BROWSERS = [["safari", "Safari"], ["chrome", "Google Chrome"]];

// Asking an app that is not running would start it.
function runningApp(name) {
  try {
    const app = Application(name);
    return app.running() ? app : null;
  } catch (e) {
    return null;
  }
}

function inTab(key, app, tab, script) {
  return key === "safari" ? app.doJavaScript(script, { in: tab }) : tab.execute({ javascript: script });
}

// The browser refuses outright when JavaScript from Apple Events is off.
function refused(error) {
  return /apple ?events|applescript|javascript/i.test(String(error && error.message));
}

ObjC.import("Foundation");

function emit(object) {
  const line = $(JSON.stringify(object) + "\n").dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(line);
}

function list(key, skip) {
  const name = (BROWSERS.find(function (b) { return b[0] === key; }) || [])[1];
  const app = name && runningApp(name);
  if (!app) return "";
  const skipped = new Set((skip || "").split(",").filter(Boolean));
  // When given, the windows as the app found them in the tab strips of
  // this desktop: each tab's description, which begins with its title, in
  // order, and the places of the tabs that may be asked. A frozen tab never
  // answers, and the browser answers nothing more until it does; a window
  // is known by all its titles in order, not by any one of them, since two
  // windows can each hold a tab of the same name.
  const given = $.NSProcessInfo.processInfo.environment.objectForKey("NPM_WINDOWS");
  const strips = given.isNil() ? null : JSON.parse(String(ObjC.unwrap(given)));
  const used = new Set();
  try {
    app.windows().forEach(function (window) {
      const windowID = String(window.id());
      const tabs = window.tabs();
      let allowed = null;
      let sounding = new Set();
      if (strips) {
        const titles = tabs.map(function (tab) { return key === "safari" ? tab.name() : tab.title(); });
        // The strip shows the window's tabs in order but leaves out those in
        // collapsed groups, so each of its tabs is looked for further along
        // the window's list, skipping what the strip does not show. A tab
        // the two name a little differently is passed over rather than
        // failing the window, and the window is the strip that matches it
        // best — most of its tabs, at least most — each strip one window.
        function places(strip) {
          const found = [];
          let next = 0;
          for (const line of strip.tabs) {
            let at = next;
            while (at < titles.length && line.indexOf(titles[at]) !== 0) at++;
            if (at === titles.length) { found.push(-1); continue; }
            found.push(at);
            next = at + 1;
          }
          return found;
        }
        let best = null;
        let bestScore = 0;
        strips.forEach(function (strip, i) {
          if (used.has(i) || !strip.tabs.length) return;
          const found = places(strip);
          const score = found.filter(function (at) { return at >= 0; }).length / strip.tabs.length;
          if (score > bestScore) { best = { i: i, found: found, strip: strip }; bestScore = score; }
        });
        if (!best || bestScore < 0.6) return;   // not on this desktop, or changed since: leave it be
        used.add(best.i);
        const matched = best.strip.awake
          .map(function (i) { return best.found[i]; })
          .filter(function (at) { return at >= 0; });
        allowed = new Set(matched);
        // The strip knows which tabs make sound, which a page that keeps no
        // playback state — Spotify — does not say.
        sounding = new Set((best.strip.sounding || [])
          .map(function (i) { return best.found[i]; })
          .filter(function (at) { return at >= 0; }));
      }
      tabs.forEach(function (tab, index) {
        // Safari's tabs have no id of their own; their place in the window serves.
        const tabID = String(key === "safari" ? index : tab.id());
        const id = key + "|" + windowID + "|" + tabID;
        if (skipped.has(id)) return;
        if (allowed && !allowed.has(index)) return;
        emit({ start: id });
        let reply;
        try {
          reply = inTab(key, app, tab, READ);
        } catch (e) {
          if (refused(e)) throw e;
          return;   // a page that may not be scripted, such as the browser's own
        }
        if (!reply) return;
        const media = JSON.parse(reply);
        if (sounding.has(index)) media.playing = true;
        media.browser = key;
        media.window = windowID;
        media.tab = tabID;
        emit({ tab: media });
      });
    });
  } catch (e) {
    if (refused(e)) emit({ blocked: true });
  }
  return "";
}

function command(key, windowID, tabID, action, value) {
  const name = (BROWSERS.find(function (b) { return b[0] === key; }) || [])[1];
  const app = name && runningApp(name);
  if (!app) return "";
  const script = act(action, value);
  for (const window of app.windows()) {
    if (String(window.id()) !== windowID) continue;
    const tabs = window.tabs();
    for (let index = 0; index < tabs.length; index++) {
      const id = key === "safari" ? String(index) : String(tabs[index].id());
      if (id !== tabID) continue;
      if (action === "focus") {
        // The tab brought to the front of its window, and the window to
        // the front of the browser, and the browser to the front.
        if (key === "safari") window.currentTab = tabs[index];
        else window.activeTabIndex = index + 1;
        window.index = 1;
        app.activate();
        return "ok";
      }
      return inTab(key, app, tabs[index], script) || "";
    }
  }
  return "";
}

function run(argv) {
  if (argv[0] === "command") return command(argv[1], argv[2], argv[3], argv[4], argv[5]);
  return list(argv[1], argv[2]);
}
