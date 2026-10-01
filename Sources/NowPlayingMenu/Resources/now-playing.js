ObjC.import("Foundation");

// The private framework is loaded by hand: there are no bridge descriptions for it.
$.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;

function reply(object) { return JSON.stringify(object); }

const cls = $.NSClassFromString("MRNowPlayingRequest");
if (!cls) {
  reply({ error: "MRNowPlayingRequest not found" });
} else {
  // Methods of a class looked up by name can only be called through a selector:
  // accessing them as properties throws a TypeError.
  const item = cls.performSelector($.NSSelectorFromString("localNowPlayingItem"));
  if (!item || item.isNil()) {
    reply({ title: null, artist: null, album: null, playbackRate: 0 });
  } else {
    const info = item.performSelector($.NSSelectorFromString("nowPlayingInfo"));
    const get = (key) => {
      if (!info || info.isNil()) return null;
      const value = info.objectForKey($(key));
      return value && !value.isNil() ? ObjC.unwrap(value) : null;
    };
    // The timestamp arrives as an NSDate. No need to unwrap it: all that is
    // needed is one moment in seconds to keep counting the position from.
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
      // The position is not the current one but the one at the timestamp: the
      // system rewrites it only when playback changes, so between polls we
      // count it forward ourselves. Not every source publishes a duration;
      // without one there is nothing to show.
      duration: get("kMRMediaRemoteNowPlayingInfoDuration") || 0,
      elapsedTime: get("kMRMediaRemoteNowPlayingInfoElapsedTime") || 0,
      timestamp: moment("kMRMediaRemoteNowPlayingInfoTimestamp")
    });
  }
}
