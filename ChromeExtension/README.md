# Now Playing Menu Bridge (Chrome extension)

Tells Now Playing Menu about every Chrome tab with an `<audio>`/`<video>`
playing or paused: title, site, position, duration, playing or paused.
They appear in the card as **Chrome · extension**, and their buttons
(play/pause, ±15 s, scrub, click artwork to open the tab) work through it.

Install: `chrome://extensions` → Developer mode → **Load unpacked** → this folder.
Tabs that were already open before installing need a reload.

Bridge: the extension POSTs its list to `http://127.0.0.1:47811/state`
about once a second; the reply carries the app's queued commands. Only
`chrome-extension://` origins (or no origin) are accepted, so web pages can't
post to it. While the extension is reporting, the app stops reading Chrome
through AppleScript. `curl localhost:47811/ping` shows whether the app is
running; what it received is told only to the extension.
