#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include "AttendingMedia.h"

// Streams Now Playing state as one JSON object per stdout line and accepts
// newline-separated commands on stdin: toggle, play, pause, next, previous,
// seek <seconds>, refresh. EOF on stdin (Attending quit) ends the process.

typedef void (*MRRegister)(dispatch_queue_t);
typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPlaying)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef NSString *(*MRClientString)(id);
typedef Boolean (*MRSend)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetPlaying getPlaying;
static MRGetClient getClient;
static MRClientString clientBundle;
static MRClientString clientParentBundle;
static MRSend sendCommand;
static MRSetElapsed setElapsed;
static NSUInteger lastArtworkHash;
static NSString *lastTitle;
static BOOL emitScheduled;

static void writeLine(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *bytes = line.bytes;
    size_t remaining = line.length;
    while (remaining > 0) {
        ssize_t written = write(STDOUT_FILENO, bytes, remaining);
        if (written <= 0) exit(0);
        bytes += written; remaining -= (size_t)written;
    }
}

static id jsonValue(id value) { return value ?: [NSNull null]; }

static void emit(void) {
    emitScheduled = NO;
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        getPlaying(dispatch_get_main_queue(), ^(BOOL playing) {
            void (^finish)(NSString *) = ^(NSString *bundle) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"empty"] = @(info.count == 0);
                out[@"playing"] = @(playing);
                out[@"bundle"] = jsonValue(bundle);
                out[@"title"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                out[@"artist"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                out[@"album"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                out[@"duration"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                out[@"elapsed"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                out[@"rate"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = [stamp isKindOfClass:[NSDate class]] ? @(stamp.timeIntervalSince1970) : [NSNull null];
                NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSUInteger hash = [artwork isKindOfClass:[NSData class]] ? artwork.hash ^ artwork.length : 0;
                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                BOOL sameTrack = (title == lastTitle) || [title isEqual:lastTitle];
                lastTitle = title;
                // Artwork is large; send it only when it changes. Players briefly drop it
                // while pausing, so keep the old image until the track itself changes.
                if (hash != lastArtworkHash && !(hash == 0 && sameTrack)) {
                    lastArtworkHash = hash;
                    out[@"artwork"] = hash ? [artwork base64EncodedStringWithOptions:0] : @"";
                }
                writeLine(out);
            };
            if (!getClient || !clientBundle) { finish(nil); return; }
            getClient(dispatch_get_main_queue(), ^(id client) {
                NSString *bundle = nil;
                if (client) {
                    // Browser tabs report a WebKit/Chromium helper; the parent is the app the user sees.
                    if (clientParentBundle) bundle = clientParentBundle(client);
                    if (bundle.length == 0) bundle = clientBundle(client);
                }
                finish(bundle);
            });
        });
    });
}

static void scheduleEmit(void) {
    if (emitScheduled) return;
    emitScheduled = YES;
    // Coalesce bursts of notifications into one update.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ emit(); });
}

static void handle(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *command = parts.firstObject;
    // MediaRemote command identifiers.
    if ([command isEqualToString:@"play"]) sendCommand(0, nil);
    else if ([command isEqualToString:@"pause"]) sendCommand(1, nil);
    else if ([command isEqualToString:@"toggle"]) sendCommand(2, nil);
    else if ([command isEqualToString:@"next"]) sendCommand(4, nil);
    else if ([command isEqualToString:@"previous"]) sendCommand(5, nil);
    else if ([command isEqualToString:@"seek"] && parts.count > 1 && setElapsed) setElapsed(MAX(0, parts[1].doubleValue));
    else if ([command isEqualToString:@"refresh"]) lastArtworkHash = 1;
    scheduleEmit();
}

void attending_media_run(void *perl, void *cv) {
    @autoreleasepool {
        void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!framework) { writeLine(@{@"error": @"MediaRemote unavailable"}); exit(1); }
        MRRegister registerNotifications = (MRRegister)dlsym(framework, "MRMediaRemoteRegisterForNowPlayingNotifications");
        getInfo = (MRGetInfo)dlsym(framework, "MRMediaRemoteGetNowPlayingInfo");
        getPlaying = (MRGetPlaying)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        getClient = (MRGetClient)dlsym(framework, "MRMediaRemoteGetNowPlayingClient");
        clientBundle = (MRClientString)dlsym(framework, "MRNowPlayingClientGetBundleIdentifier");
        clientParentBundle = (MRClientString)dlsym(framework, "MRNowPlayingClientGetParentAppBundleIdentifier");
        sendCommand = (MRSend)dlsym(framework, "MRMediaRemoteSendCommand");
        setElapsed = (MRSetElapsed)dlsym(framework, "MRMediaRemoteSetElapsedTime");
        if (!registerNotifications || !getInfo || !getPlaying || !sendCommand) { writeLine(@{@"error": @"MediaRemote symbols unavailable"}); exit(1); }
        registerNotifications(dispatch_get_main_queue());
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{ scheduleEmit(); });
            }];
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char *buffer = NULL; size_t capacity = 0; ssize_t length;
            while ((length = getline(&buffer, &capacity, stdin)) > 0) {
                NSString *line = [[[NSString alloc] initWithBytes:buffer length:(NSUInteger)length encoding:NSUTF8StringEncoding]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (line.length == 0) continue;
                dispatch_async(dispatch_get_main_queue(), ^{ handle(line); });
            }
            exit(0);
        });
        scheduleEmit();
    }
    CFRunLoopRun();
}
