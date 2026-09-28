# Now Playing Menu

See what's playing — artist and title — right in the menu bar.

**[Download NowPlayingMenu.zip](https://github.com/yjujq/NowPlayingMenu/releases/latest/download/NowPlayingMenu.zip)**

## What it does

- Shows `Artist — Title` from Music, Spotify, browsers and anything else that appears in Control Center's Now Playing.
- A thin line under the title shows how far into the track you are.
- Click to play or pause; right-click for the menu.
- Settings for static, scrolling or paged text, width, alignment, font, size and speed.
- Uses almost no CPU: the motion runs in Core Animation, not on a timer.

## Manual

<img src="docs/menu.png" width="520" alt="The track in the menu bar and its menu">

1. **Start playing** something anywhere — the menu bar shows `Artist — Title`, with a thin progress line under it.
2. **Click it** to play or pause.
3. **Right-click it** (two-finger click on a trackpad) for the menu: the track, **Settings…**, **Refresh** and **Quit**.
4. In **Settings…** choose how the text moves, its width, font and size, and whether the progress line shows.

## Install

1. Download **NowPlayingMenu.zip**, unzip it and move **NowPlayingMenu.app** to Applications.
2. Open it. The app is not notarized, so macOS stops it the first time: open **System Settings → Privacy & Security** and click **Open Anyway**.

## Requirements

macOS 13 or later.

## Permissions

None.

## Good to know

- Track details come from the system's private MediaRemote framework, read through `osascript`. Fine for personal use; it could not ship on the Mac App Store.
- Some sources, such as video in a browser, publish no track length — then there is no progress line.

## Build from source

```sh
swift run
```

Or `./make-app.sh --install` to build the app into Applications.

## Privacy

Now Playing Menu collects nothing and makes no network connections. Track details are read from your own Mac and stay there.

## License

MIT — see [LICENSE](LICENSE).
