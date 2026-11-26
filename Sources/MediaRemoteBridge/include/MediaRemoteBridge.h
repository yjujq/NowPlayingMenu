#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MediaRemote command IDs, as the system numbers them.
typedef NS_ENUM(int, MRBCommand) {
    MRBCommandPlay = 0,
    MRBCommandPause = 1,
    MRBCommandTogglePlayPause = 2,
    MRBCommandNextTrack = 4,
    MRBCommandPreviousTrack = 5,
    MRBCommandSkipForward = 17,
    MRBCommandSkipBackward = 18,
    MRBCommandSeekToPlaybackPosition = 24,
};

/// Sends a MediaRemote command to the active system player.
BOOL MRBSendCommand(MRBCommand command);

/// Skips forward or back by `seconds`, for players that skip rather than
/// change track — video in a browser, a podcast.
BOOL MRBSkip(BOOL forward, double seconds);

/// Sends the MediaRemote Toggle Play/Pause command to the active system player.
BOOL MRBTogglePlayPause(void);

/// Moves the active player to `seconds` into the track. NO if the framework
/// does not export the call.
BOOL MRBSetElapsedTime(double seconds);

NS_ASSUME_NONNULL_END
