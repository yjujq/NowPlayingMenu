#import <Foundation/Foundation.h>

/// Writes the artwork of the current Now Playing item to standard output, as
/// the image file the player published (JPEG or PNG), or nothing if there is
/// none. The two arguments are the ones Perl hands an XSUB and are ignored.
void NPMWriteArtwork(void *interpreter, void *cv);

/// Writes every player the system knows of that has something loaded — not
/// only the one Control Center puts first — to standard output as a JSON
/// array. Each entry has `id`, `source` (the app's bundle identifier), `name`,
/// `title`, `artist`, `album`, `playbackRate`, `duration`, `elapsedTime`,
/// `timestamp` (seconds since 1970), `artworkKey`, `commands` (the numbers
/// of the commands it takes), `skipInterval`, `scrubbable` (false only when
/// the bar may not be dragged), `tint` (red, green, blue), `target` (true
/// for the player the system sends commands to); and
/// `artwork`, base64, unless its key is one of the lines in the environment
/// variable NPM_KNOWN_ARTWORK.
void NPMWritePlayers(void *interpreter, void *cv);

/// Sends the MediaRemote command numbered NPM_COMMAND to the player whose
/// `id` is NPM_PLAYER, both read from the environment. NPM_POSITION, in
/// seconds, goes with the command to seek (24).
void NPMSendPlayerCommand(void *interpreter, void *cv);

/// Plays or pauses the app the system sends commands to: asks whether it is
/// playing and sends Pause or Play outright, since some players — Safari —
/// take no Toggle.
void NPMTogglePlayPause(void *interpreter, void *cv);

/// Writes what the system reports as now playing — the item now-playing.js
/// reads — as JSON with the same keys, its `playbackRate` 0 whenever the
/// player is not playing, whatever rate it left in its info.
void NPMWriteNowPlaying(void *interpreter, void *cv);
