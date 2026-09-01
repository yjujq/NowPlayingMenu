# Now Playing Menu

A minimal macOS 13+ app that shows the current track known to the system Now Playing controls. The menu bar displays `Artist — Title` in a fixed-width area, using the standard macOS menu-bar font. The text is static; an exceptionally long one is shortened with an ellipsis. When nothing is playing, it shows a single Play icon. Click it to open `Refresh` and `Quit`.

When no media is playing, the Status Bar item automatically shrinks to the size of the Play icon.

Choose `Settings…` from the Status Bar menu to customize the display. Settings include static, scrolling, or paged text; width; alignment; artist and album visibility; system, condensed, monospaced, or rounded fonts; font size; scrolling direction and speed; page interval; and a one-click reset. They are saved automatically.

Left-click the Status Bar display to toggle the system Play/Pause command. Right-click it to open the menu containing `Settings…`, `Refresh`, and `Quit`.

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
