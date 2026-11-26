#import "MediaRemoteBridge.h"
#import <dlfcn.h>

typedef BOOL (*MRSendCommand)(int command, CFDictionaryRef _Nullable options);
typedef void (*MRSetElapsedTime)(double seconds);

static void *MRBFramework(void) {
    static void *framework;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    return framework;
}

BOOL MRBSendCommand(MRBCommand command) {
    static MRSendCommand sendCommand;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *framework = MRBFramework();
        sendCommand = framework ? (MRSendCommand)dlsym(framework, "MRMediaRemoteSendCommand") : NULL;
    });
    return sendCommand ? sendCommand(command, NULL) : NO;
}

BOOL MRBSkip(BOOL forward, double seconds) {
    void *framework = MRBFramework();
    MRSendCommand sendCommand = framework ? (MRSendCommand)dlsym(framework, "MRMediaRemoteSendCommand") : NULL;
    CFStringRef *intervalKey = framework ? dlsym(framework, "kMRMediaRemoteOptionSkipInterval") : NULL;
    if (!sendCommand || !intervalKey) return NO;
    NSDictionary *options = @{ (__bridge NSString *)*intervalKey: @(seconds) };
    return sendCommand(forward ? MRBCommandSkipForward : MRBCommandSkipBackward, (__bridge CFDictionaryRef)options);
}

BOOL MRBTogglePlayPause(void) {
    return MRBSendCommand(MRBCommandTogglePlayPause);
}

BOOL MRBSetElapsedTime(double seconds) {
    static MRSetElapsedTime setElapsedTime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *framework = MRBFramework();
        setElapsedTime = framework ? (MRSetElapsedTime)dlsym(framework, "MRMediaRemoteSetElapsedTime") : NULL;
    });
    if (!setElapsedTime) return NO;
    setElapsedTime(seconds);
    return YES;
}
