#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MediaRemote command IDs, as the system numbers them.
typedef NS_ENUM(int, MRBCommand) {
    MRBCommandTogglePlayPause = 2,
    MRBCommandNextTrack = 4,
    MRBCommandPreviousTrack = 5,
};

/// Sends a MediaRemote command to the active system player.
BOOL MRBSendCommand(MRBCommand command);

/// Sends the MediaRemote Toggle Play/Pause command to the active system player.
BOOL MRBTogglePlayPause(void);

/// Moves the active player to `seconds` into the track. NO if the framework
/// does not export the call.
BOOL MRBSetElapsedTime(double seconds);

NS_ASSUME_NONNULL_END
