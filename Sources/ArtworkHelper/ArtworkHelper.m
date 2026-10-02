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

// MARK: - Every player
//
// The calls below are not declared anywhere; their shapes were read off the
// framework's machine code on macOS 27. Each is looked up by name and the
// work is skipped if it is missing.

typedef void (^NPMArrayReply)(CFArrayRef);
typedef void (^NPMInfoReply)(CFDictionaryRef);
typedef void (^NPMCommandReply)(id);

static void *NPMFramework(void) {
    return dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
}

/// Turns the run loop until `answered` or two seconds pass: the replies come
/// on the main queue, and nothing else here would serve it.
static void NPMWait(BOOL *answered) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!*answered && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

static NSString *NPMString(id object, NSString *key) {
    if (!object || ![object respondsToSelector:NSSelectorFromString(key)]) return nil;
    id value = [object valueForKey:key];
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

/// Calls `visit` with each player of each app that has one, and the path
/// that names it to the other calls.
static void NPMEachPlayer(void (^visit)(id client, id player, id path)) {
    void *framework = NPMFramework();
    if (!framework) return;
    void (*getClients)(dispatch_queue_t, NPMArrayReply) = dlsym(framework, "MRMediaRemoteGetNowPlayingClients");
    void (*getPlayers)(id, id, dispatch_queue_t, NPMArrayReply) = dlsym(framework, "MRMediaRemoteGetPlayersForClient");
    id (*localOrigin)(void) = dlsym(framework, "MRMediaRemoteGetLocalOrigin");
    Class pathClass = NSClassFromString(@"MRPlayerPath");
    SEL makePath = NSSelectorFromString(@"initWithOrigin:client:player:");
    if (!getClients || !getPlayers || !localOrigin || ![pathClass instancesRespondToSelector:makePath]) return;
    id origin = localOrigin();

    __block NSArray *clients = nil;
    __block BOOL answered = NO;
    getClients(dispatch_get_main_queue(), ^(CFArrayRef list) {
        clients = [(__bridge NSArray *)list copy];
        answered = YES;
    });
    NPMWait(&answered);

    for (id client in clients) {
        __block NSArray *players = nil;
        answered = NO;
        getPlayers(client, origin, dispatch_get_main_queue(), ^(CFArrayRef list) {
            players = [(__bridge NSArray *)list copy];
            answered = YES;
        });
        NPMWait(&answered);
        for (id player in players) {
            id path = ((id (*)(id, SEL, id, id, id))objc_msgSend)([pathClass alloc], makePath, origin, client, player);
            if (path) visit(client, player, path);
        }
    }
}

/// The app, its process — two browser windows are two of them — and the
/// player within it.
static NSString *NPMPlayerID(id client, id player) {
    SEL pid = NSSelectorFromString(@"processIdentifier");
    id process = [client respondsToSelector:pid] ? [client valueForKey:@"processIdentifier"] : @0;
    return [NSString stringWithFormat:@"%@|%@|%@", NPMString(client, @"bundleIdentifier") ?: @"",
                                                   process, NPMString(player, @"identifier") ?: @""];
}

static NSDictionary *NPMInfo(id path, BOOL withArtwork) {
    void (*getInfo)(id, BOOL, dispatch_queue_t, NPMInfoReply) =
        dlsym(NPMFramework(), "MRMediaRemoteGetNowPlayingInfoForPlayer");
    if (!getInfo) return nil;
    __block NSDictionary *info = nil;
    __block BOOL answered = NO;
    getInfo(path, withArtwork, dispatch_get_main_queue(), ^(CFDictionaryRef reply) {
        info = [(__bridge NSDictionary *)reply copy];
        answered = YES;
    });
    NPMWait(&answered);
    return info;
}

/// What the player says it can do — the same list Control Center reads to
/// choose its buttons: the enabled commands by number, the skip interval,
/// and whether the bar may be dragged.
static void NPMAddCommands(NSMutableDictionary *entry, id path) {
    void (*getCommands)(id, dispatch_queue_t, NPMArrayReply) =
        dlsym(NPMFramework(), "MRMediaRemoteGetSupportedCommandsForPlayer");
    CFStringRef *skipKey = dlsym(NPMFramework(), "kMRMediaRemoteOptionSkipInterval");
    CFStringRef *scrubKey = dlsym(NPMFramework(), "kMRMediaRemoteCommandInfoCanBeControlledByScrubbingKey");
    if (!getCommands) return;
    __block NSArray *infos = nil;
    __block BOOL answered = NO;
    getCommands(path, dispatch_get_main_queue(), ^(CFArrayRef list) {
        infos = [(__bridge NSArray *)list copy];
        answered = YES;
    });
    NPMWait(&answered);

    NSMutableArray *commands = [NSMutableArray array];
    for (id info in infos) {
        if (![[info valueForKey:@"enabled"] boolValue]) continue;
        NSNumber *command = [info valueForKey:@"command"];
        NSDictionary *options = [info valueForKey:@"options"];
        [commands addObject:command];
        if (![options isKindOfClass:NSDictionary.class]) continue;
        id interval = skipKey ? options[(__bridge NSString *)*skipKey] : nil;
        if ([interval isKindOfClass:NSArray.class]) interval = [interval firstObject];
        if ([interval isKindOfClass:NSNumber.class]) entry[@"skipInterval"] = interval;
        id scrubs = scrubKey ? options[(__bridge NSString *)*scrubKey] : nil;
        if ([scrubs isKindOfClass:NSNumber.class] && ![scrubs boolValue]) entry[@"scrubbable"] = @NO;
    }
    entry[@"commands"] = commands;
}

/// The app's own colour, where it has given one; QuickTime's is blue.
static void NPMAddTint(NSMutableDictionary *entry, id client) {
    if (![client respondsToSelector:NSSelectorFromString(@"tintColor")]) return;
    id tint = [client valueForKey:@"tintColor"];
    if (!tint || ![tint respondsToSelector:NSSelectorFromString(@"red")]) return;
    entry[@"tint"] = @[[tint valueForKey:@"red"], [tint valueForKey:@"green"], [tint valueForKey:@"blue"]];
}

/// The app the system sends commands to — not always the one it reports as
/// now playing — as its bundle identifier and process.
static NSString *NPMCommandTarget(void) {
    void (*getClient)(dispatch_queue_t, void (^)(id)) = dlsym(NPMFramework(), "MRMediaRemoteGetNowPlayingClient");
    if (!getClient) return nil;
    __block id target = nil;
    __block BOOL answered = NO;
    getClient(dispatch_get_main_queue(), ^(id client) {
        target = client;
        answered = YES;
    });
    NPMWait(&answered);
    if (!target) return nil;
    SEL pid = NSSelectorFromString(@"processIdentifier");
    id process = [target respondsToSelector:pid] ? [target valueForKey:@"processIdentifier"] : @0;
    return [NSString stringWithFormat:@"%@|%@", NPMString(target, @"bundleIdentifier") ?: @"", process];
}

/// Whether the player is playing, by its playback state (1 is playing) —
/// not by the rate in its info, which some players leave at 1 when paused:
/// VLC does, and its time then ran on in the card while it stood still.
/// Nil when the state cannot be had.
static NSNumber *NPMIsPlaying(id path) {
    void (*getState)(id, dispatch_queue_t, void (^)(unsigned int)) =
        dlsym(NPMFramework(), "MRMediaRemoteGetPlaybackStateForPlayer");
    if (!getState) return nil;
    __block NSNumber *playing = nil;
    __block BOOL answered = NO;
    getState(path, dispatch_get_main_queue(), ^(unsigned int state) {
        playing = @(state == 1);
        answered = YES;
    });
    NPMWait(&answered);
    return playing;
}

void NPMWritePlayers(void *interpreter, void *cv) {
    @autoreleasepool {
        NSString *target = NPMCommandTarget();
        const char *known = getenv("NPM_KNOWN_ARTWORK");
        NSSet *knownArtwork = [NSSet setWithArray:
            [@(known ?: "") componentsSeparatedByString:@"\n"]];
        NSMutableArray *players = [NSMutableArray array];

        NPMEachPlayer(^(id client, id player, id path) {
            NSDictionary *info = NPMInfo(path, NO);
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            // A player that names no track — QuickTime with a film open — is
            // listed under its app's name, as Control Center lists it.
            if (![title isKindOfClass:NSString.class] || title.length == 0) title = NPMString(client, @"displayName");
            if (title.length == 0) return;
            NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
            NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
            // The picture's own name when the player gives one; otherwise the
            // track, which changes when the picture does.
            NSString *artworkKey = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
            if (![artworkKey isKindOfClass:NSString.class]) {
                artworkKey = [@[title, artist, album] componentsJoinedByString:@"\x1F"];
            }

            NSMutableDictionary *entry = [@{
                @"id": NPMPlayerID(client, player),
                // A browser rather than WebKit when the sound is from the web.
                @"source": NPMString(client, @"parentApplicationBundleIdentifier")
                           ?: NPMString(client, @"bundleIdentifier") ?: @"",
                @"name": NPMString(client, @"displayName") ?: @"",
                @"title": title,
                @"artist": [artist isKindOfClass:NSString.class] ? artist : @"",
                @"album": [album isKindOfClass:NSString.class] ? album : @"",
                @"playbackRate": [NPMIsPlaying(path) isEqual:@NO]
                                 ? @0 : (info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0),
                @"duration": info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0,
                @"elapsedTime": info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0,
                @"artworkKey": artworkKey,
            } mutableCopy];
            NSDate *taken = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([taken isKindOfClass:NSDate.class]) entry[@"timestamp"] = @(taken.timeIntervalSince1970);
            NPMAddCommands(entry, path);
            NPMAddTint(entry, client);
            if (target && [entry[@"id"] hasPrefix:[target stringByAppendingString:@"|"]]) entry[@"target"] = @YES;
            if (![knownArtwork containsObject:artworkKey]) {
                NSData *image = NPMInfo(path, YES)[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([image isKindOfClass:NSData.class] && image.length > 0) {
                    entry[@"artwork"] = [image base64EncodedStringWithOptions:0];
                }
            }
            [players addObject:entry];
        });

        NSData *json = [NSJSONSerialization dataWithJSONObject:players options:0 error:nil];
        if (json) {
            fwrite(json.bytes, 1, json.length, stdout);
            fflush(stdout);
        }
    }
}

void NPMSendPlayerCommand(void *interpreter, void *cv) {
    @autoreleasepool {
        const char *wanted = getenv("NPM_PLAYER");
        const char *command = getenv("NPM_COMMAND");
        if (!wanted || !command) return;
        NSString *target = @(wanted);
        BOOL (*send)(int, CFDictionaryRef, id, unsigned int, dispatch_queue_t, NPMCommandReply) =
            dlsym(NPMFramework(), "MRMediaRemoteSendCommandToPlayer");
        if (!send) return;

        __block id targetPath = nil;
        NPMEachPlayer(^(id client, id player, id path) {
            if (!targetPath && [NPMPlayerID(client, player) isEqualToString:target]) targetPath = path;
        });
        if (!targetPath) return;

        // Seeking carries the position along, as MRMediaRemoteSetElapsedTime
        // does for the player in front.
        NSDictionary *options = nil;
        const char *position = getenv("NPM_POSITION");
        CFStringRef *positionKey = dlsym(NPMFramework(), "kMRMediaRemoteOptionPlaybackPosition");
        if (position && positionKey) options = @{ (__bridge NSString *)*positionKey: @(atof(position)) };

        __block BOOL answered = NO;
        send(atoi(command), (__bridge CFDictionaryRef)options, targetPath, 0, dispatch_get_main_queue(),
             ^(id result) { answered = YES; });
        NPMWait(&answered);
    }
}

void NPMTogglePlayPause(void *interpreter, void *cv) {
    @autoreleasepool {
        void *framework = NPMFramework();
        void (*isPlaying)(dispatch_queue_t, void (^)(BOOL)) =
            dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        BOOL (*send)(int, CFDictionaryRef) = dlsym(framework, "MRMediaRemoteSendCommand");
        void (*getPID)(dispatch_queue_t, void (^)(int)) = dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationPID");
        if (!isPlaying || !send || !getPID) return;

        __block BOOL playing = NO;
        __block BOOL answered = NO;
        isPlaying(dispatch_get_main_queue(), ^(BOOL value) {
            playing = value;
            answered = YES;
        });
        NPMWait(&answered);
        send(playing ? 1 : 0, NULL);

        // The command goes out on its own time; a round trip to the daemon
        // after it sees it gone before the process ends.
        answered = NO;
        getPID(dispatch_get_main_queue(), ^(int pid) { answered = YES; });
        NPMWait(&answered);
    }
}

void NPMWriteNowPlaying(void *interpreter, void *cv) {
    @autoreleasepool {
        if (!NPMFramework()) return;
        Class request = NSClassFromString(@"MRNowPlayingRequest");
        SEL itemSelector = NSSelectorFromString(@"localNowPlayingItem");
        SEL pathSelector = NSSelectorFromString(@"localNowPlayingPlayerPath");
        SEL playingSelector = NSSelectorFromString(@"localIsPlaying");
        if (![request respondsToSelector:itemSelector]) return;
        id (*object)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        BOOL (*flag)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;

        id item = object(request, itemSelector);
        id path = [request respondsToSelector:pathSelector] ? object(request, pathSelector) : nil;
        BOOL playing = [request respondsToSelector:playingSelector] ? flag(request, playingSelector) : YES;
        NSDictionary *info = [item respondsToSelector:NSSelectorFromString(@"nowPlayingInfo")]
            ? [item valueForKey:@"nowPlayingInfo"] : nil;

        NSMutableDictionary *reply = [NSMutableDictionary dictionary];
        NSDictionary *keys = @{
            @"title": @"kMRMediaRemoteNowPlayingInfoTitle",
            @"artist": @"kMRMediaRemoteNowPlayingInfoArtist",
            @"album": @"kMRMediaRemoteNowPlayingInfoAlbum",
            @"duration": @"kMRMediaRemoteNowPlayingInfoDuration",
            @"elapsedTime": @"kMRMediaRemoteNowPlayingInfoElapsedTime",
            @"artworkIdentifier": @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier",
        };
        for (NSString *key in keys) {
            id value = info[keys[key]];
            if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) reply[key] = value;
        }
        NSDate *taken = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([taken isKindOfClass:NSDate.class]) reply[@"timestamp"] = @(taken.timeIntervalSince1970);
        // Paused is paused, whatever rate the player left in its info.
        reply[@"playbackRate"] = playing ? (info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @1) : @0;
        id client = [path respondsToSelector:NSSelectorFromString(@"client")] ? [path valueForKey:@"client"] : nil;
        NSString *source = NPMString(client, @"parentApplicationBundleIdentifier") ?: NPMString(client, @"bundleIdentifier");
        if (source) reply[@"source"] = source;

        NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
        if (json) {
            fwrite(json.bytes, 1, json.length, stdout);
            fflush(stdout);
        }
    }
}
