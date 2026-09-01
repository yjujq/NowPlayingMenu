#import "MediaRemoteBridge.h"
#import <dlfcn.h>

typedef BOOL (*MRSendCommand)(int command, CFDictionaryRef _Nullable options);

static void *MRBFramework(void) {
    static void *framework;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    return framework;
}

BOOL MRBTogglePlayPause(void) {
    static MRSendCommand sendCommand;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *framework = MRBFramework();
        sendCommand = framework ? (MRSendCommand)dlsym(framework, "MRMediaRemoteSendCommand") : NULL;
    });
    // Command ID 2 is kMRTogglePlayPause.
    return sendCommand ? sendCommand(2, NULL) : NO;
}
