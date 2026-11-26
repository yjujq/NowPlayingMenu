// Runs in the page's own world. Players such as SoundCloud and Spotify play
// from an <audio>/<video> they never put in the document (or keep in a
// shadow root), so content.js cannot find it and its events never reach the
// document. Every play() is announced here: the element itself crosses to
// the extension's world as the event's relatedTarget, and an id finds it
// inside a shadow root, where relatedTarget points at the host instead.
(() => {
  if (window.__nowPlayingMain) return;
  window.__nowPlayingMain = true;
  let next = 1;
  const announce = (el) => {
    try {
      if (el.isConnected && el.getRootNode() === document) return;
      if (!el.dataset.npmId) el.dataset.npmId = "m" + next++;
      document.documentElement && document.documentElement.setAttribute("data-npm-last", el.dataset.npmId);
      document.dispatchEvent(new MouseEvent("__nowplaying_media", { relatedTarget: el }));
    } catch (e) {}
  };
  // The page's own Media Session handlers — what Chrome's media controls
  // press. Kept here so the app's buttons press the same ones: a player like
  // Spotify ignores its element being played directly, and a background tab
  // may refuse play() from a script.
  const handlers = {};
  const session = navigator.mediaSession;
  if (session && session.setActionHandler) {
    const set = session.setActionHandler.bind(session);
    session.setActionHandler = function (action, handler) {
      handlers[action] = handler;
      const names = Object.keys(handlers).filter((k) => handlers[k]);
      try { document.documentElement.setAttribute("data-npm-actions", names.join(" ")); } catch (e) {}
      return set(action, handler);
    };
  }
  document.addEventListener("__nowplaying_cmd", (e) => {
    try {
      const { action, value } = JSON.parse(e.detail);
      const h = handlers[action];
      if (!h) return;
      const details = { action };
      if (action === "seekto") details.seekTime = value;
      if (action === "seekforward" || action === "seekbackward") details.seekOffset = Math.abs(value);
      h(details);
    } catch (err) {}
  });
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () { announce(this); return play.apply(this, arguments); };
})();
