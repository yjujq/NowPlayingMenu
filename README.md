# Now Playing Menu

A minimal macOS 13+ app that shows the current track known to the system Now Playing controls. The menu bar displays `Artist — Title` in a fixed-width area, using the standard macOS menu-bar font. The text is static; an exceptionally long one is shortened with an ellipsis. When nothing is playing, it shows a single Play icon.

When no media is playing, the Status Bar item automatically shrinks to the size of the Play icon.

Choose `Settings…` from the Status Bar menu to customize the display. The panel groups its rows into cards over the
window's blur. Settings include static, scrolling, or paged text; width; alignment; artist and album visibility;
system, condensed, monospaced, or rounded fonts; font size; scrolling direction and speed; page interval; and a
one-click reset. The Motion rows that the current mode does not use are dimmed rather than hidden, so the panel keeps
its shape. Settings are saved automatically.

The line is a layer inside the Status Bar item rather than the button's title, so it moves by fractions of a point
instead of a glyph at a time, and its width is measured rather than estimated. A line that already fits the item does
not move at all, whatever the mode is set to — there is nothing for the motion to reveal.

The motion itself is one Core Animation, handed over once and repeated for as long as the track lasts: the line and a
copy of it are drawn on a single strip, and the strip slides by exactly one loop, so the restart is invisible. Setting
`button.image` on a timer instead is what the first version did, and it is not affordable at any frame rate worth
having — every change to the content of a status item makes AppKit re-snapshot the whole item, and thirty frames a
second cost a quarter of a core. Animated as a layer it costs nothing per frame: the app is never woken for a frame,
and its timer only wakes twice a second to notice a new track, a changed setting, or the menu bar turning dark.

Left-click the Status Bar display to toggle the system Play/Pause command. Right-click it — a two-finger click on a
trackpad — to open the menu. It opens on a header carrying the playback state, the track title, and the artist and
album, and below it `Settings…`, `Refresh`, and `Quit`, each with its symbol and keyboard shortcut. The menu is drawn
by AppKit as an ordinary menu, so its metrics, its highlight and its vibrancy are the system's own. It is given the
app's appearance explicitly: a menu popped up from a Status Bar button otherwise inherits that button's appearance,
which is the menu bar's own vibrant one and follows the desktop picture rather than the system's light or dark
setting — which left the menu light on a dark system.

The app reads the system-wide macOS media session, the same session used by Control Center. It uses the system `osascript` process because recent macOS releases block direct MediaRemote access from ordinary apps. It supports Music, Spotify, browsers, and other applications **when they publish playback to the system Now Playing session**. If several sources play simultaneously, macOS selects one system-primary session.

## Run

In Terminal, from this project directory:

```sh
swift run
```

Or open `Package.swift` in Xcode and press Run. The app will appear in the menu bar.

## Important

Metadata comes from the system Now Playing session through `MediaRemote`, a
private system framework. Recent macOS releases answer such requests only for
Apple's own entitled processes: calling the framework directly from this app
returns an empty result with no error. The app therefore runs the query inside
`/usr/bin/osascript`, which does get an answer. That is why a helper process is
spawned on every poll instead of linking the framework directly.

The consequence: this is suitable for personal use, not for the Mac App Store.
A distributable version would have to use the public interfaces of individual
players such as Music or Spotify rather than the shared system session.

The bundled `MediaRemoteBridge` is used only to send the play/pause command; it
does not read metadata.
