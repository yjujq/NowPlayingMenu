#import "ArtworkHelper.h"
#import <dlfcn.h>
#import <objc/message.h>

// This library is never linked into the app. The app cannot ask for the
// artwork itself: since macOS 15.4 mediaremoted answers that request only for
// processes signed by Apple, and this one is not. So the app starts the
// system's /usr/bin/perl, which is, has it load this library, and calls the
// function below as an XSUB; the image comes back on the pipe.
//
// It has to be a call after loading rather than a constructor: a constructor
// runs while dyld holds its lock, and the reply, delivered on another thread,
// waits on that lock for as long as the constructor waits for the reply.
void NPMWriteArtwork(void *interpreter, void *cv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        Class requestClass = NSClassFromString(@"MRNowPlayingRequest");
        SEL ask = NSSelectorFromString(@"requestNowPlayingItemArtworkWithCompletion:");
        id request = [[requestClass alloc] init];
        if (![request respondsToSelector:ask]) return;

        __block NSData *image = nil;
        __block BOOL answered = NO;
        void (^completion)(id, NSError *) = ^(id artwork, NSError *error) {
            SEL data = NSSelectorFromString(@"imageData");
            if ([artwork respondsToSelector:data]) image = [artwork valueForKey:@"imageData"];
            answered = YES;
        };
        ((void (*)(id, SEL, id))objc_msgSend)(request, ask, completion);

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (!answered && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        if (image.length > 0) {
            fwrite(image.bytes, 1, image.length, stdout);
            fflush(stdout);
        }
    }
}
