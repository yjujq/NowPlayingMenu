ObjC.import("Foundation");

// Приватный фреймворк грузим вручную: описаний мостов для него нет.
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;

function reply(object) { return JSON.stringify(object); }

const cls = $.NSClassFromString("MRNowPlayingRequest");
if (!cls) {
  reply({ error: "MRNowPlayingRequest not found" });
} else {
  // Методы класса, полученного по имени, вызываются только через селектор:
  // обращение к ним как к свойствам даёт TypeError.
  const item = cls.performSelector($.NSSelectorFromString("localNowPlayingItem"));
  // The app that is playing. Web audio is played by WebKit's GPU process on
  // behalf of a browser, and then the browser is the parent.
  const source = (() => {
    const path = cls.performSelector($.NSSelectorFromString("localNowPlayingPlayerPath"));
    if (!path || path.isNil()) return null;
    const client = path.performSelector($.NSSelectorFromString("client"));
    if (!client || client.isNil()) return null;
    for (const key of ["parentApplicationBundleIdentifier", "bundleIdentifier"]) {
      const id = client.performSelector($.NSSelectorFromString(key));
      if (id && !id.isNil() && id.js) return id.js;
    }
    return null;
  })();
  if (!item || item.isNil()) {
    reply({ title: null, artist: null, album: null, playbackRate: 0 });
  } else {
    const info = item.performSelector($.NSSelectorFromString("nowPlayingInfo"));
    const get = (key) => {
      if (!info || info.isNil()) return null;
      const value = info.objectForKey($(key));
      return value && !value.isNil() ? ObjC.unwrap(value) : null;
    };
    // Отметка времени приходит как NSDate. Разворачивать её незачем — нужен
    // один момент в секундах, от которого продолжается отсчёт позиции.
    const moment = (key) => {
      if (!info || info.isNil()) return null;
      const value = info.objectForKey($(key));
      return value && !value.isNil() ? value.timeIntervalSince1970 : null;
    };
    reply({
      title: get("kMRMediaRemoteNowPlayingInfoTitle"),
      artist: get("kMRMediaRemoteNowPlayingInfoArtist"),
      album: get("kMRMediaRemoteNowPlayingInfoAlbum"),
      playbackRate: get("kMRMediaRemoteNowPlayingInfoPlaybackRate") || 0,
      // Позиция — не текущая, а та, что была на момент timestamp: система
      // переписывает её только когда воспроизведение меняется, поэтому
      // между опросами её досчитывают сами. Длительность публикует не
      // всякий источник; без неё показывать нечего.
      duration: get("kMRMediaRemoteNowPlayingInfoDuration") || 0,
      elapsedTime: get("kMRMediaRemoteNowPlayingInfoElapsedTime") || 0,
      timestamp: moment("kMRMediaRemoteNowPlayingInfoTimestamp"),
      // The picture itself is not in this dictionary, only a name for it
      // that changes with it; the app fetches the picture when it does.
      artworkIdentifier: get("kMRMediaRemoteNowPlayingInfoArtworkIdentifier"),
      source: source
    });
  }
}
