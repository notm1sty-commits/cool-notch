// MediaBridge — помощник Cool Notch для чтения системного «Что играет».
//
// Начиная с macOS 15.4 Apple отдаёт данные Now Playing (MediaRemote) только
// своим процессам. Поэтому Cool Notch запускает системный /usr/bin/perl, тот
// загружает эту библиотеку и вызывает coolnotch_bridge_run(). Дальше библиотека:
//   • пишет в stdout по одной JSON-строке на каждое изменение трека;
//   • читает из stdin команды: play, pause, toggle, next, prev, seek <сек>, refresh;
//   • завершается, когда закрывается stdin (то есть когда закрылся Cool Notch).
//
// Так чёлка видит любой плеер: приложение Яндекс Музыки, браузер, Spotify и т. д.
// Пользователь может выключить это в настройках Cool Notch.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*MRGetNowPlayingInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedTimeFn)(double);

static MRGetNowPlayingInfoFn gGetInfo = NULL;
static MRGetIsPlayingFn gGetIsPlaying = NULL;
static MRGetPIDFn gGetPID = NULL;
static MRRegisterFn gRegister = NULL;
static MRSendCommandFn gSendCommand = NULL;
static MRSetElapsedTimeFn gSetElapsed = NULL;

static NSString *gLastArtworkKey = nil;
static BOOL gRefreshScheduled = NO;
static BOOL gRefreshInFlight = NO;
static BOOL gRefreshPending = NO;
static CFAbsoluteTime gRefreshStarted = 0;
static NSMutableData *gInputBuffer = nil;

static void emitJSON(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (data == nil) {
        return;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *stringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
}

static double doubleValue(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value doubleValue] : 0;
}

static void emitInfo(NSDictionary *info, BOOL playing, int pid) {
    NSString *title = stringValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    if (title.length == 0) {
        gLastArtworkKey = nil;
        emitJSON(@{ @"type": @"info", @"empty": @YES });
        return;
    }

    NSString *artist = stringValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    NSString *album = stringValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    double time = [timestamp isKindOfClass:[NSDate class]]
        ? [(NSDate *)timestamp timeIntervalSince1970]
        : [[NSDate date] timeIntervalSince1970];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"type"] = @"info";
    out[@"empty"] = @NO;
    out[@"title"] = title;
    out[@"artist"] = artist;
    out[@"album"] = album;
    out[@"duration"] = @(doubleValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]));
    out[@"elapsed"] = @(doubleValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]));
    out[@"rate"] = @(doubleValue(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]));
    out[@"timestamp"] = @(time);
    out[@"playing"] = @(playing);
    out[@"pid"] = @(pid);

    id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:[NSData class]] && [(NSData *)artwork length] > 0) {
        NSData *artworkData = (NSData *)artwork;
        out[@"hasArtwork"] = @YES;
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%lu", title, artist, album, (unsigned long)artworkData.length];
        if (![key isEqualToString:gLastArtworkKey]) {
            gLastArtworkKey = key;
            out[@"artwork"] = [artworkData base64EncodedStringWithOptions:0];
        }
    } else {
        out[@"hasArtwork"] = @NO;
        gLastArtworkKey = nil;
    }

    emitJSON(out);
}

static void scheduleRefresh(void);
static void refreshNow(void);

/// Запросы идут строго по одному: пока один не ответил, новые события только помечают
/// «нужно ещё раз». Раньше более свежий запрос отменял текущий, и плееры, которые
/// обновляют позицию очень часто (приложение Яндекс Музыки), не успевали показаться вовсе.
static void finishRefresh(void) {
    gRefreshInFlight = NO;
    if (gRefreshPending) {
        gRefreshPending = NO;
        refreshNow();
    }
}

/// Название трека, «играет ли» и PID приложения MediaRemote отдаёт разными вызовами.
/// Если между ними система переключилась на другой плеер (видео ↔ музыка), данные
/// перемешивались, и карточки мигали. Поэтому сверяем PID до и после и при расхождении
/// спрашиваем заново (не больше двух раз — дальше отдаём то, что есть).
static void performRefresh(int attempt) {
    dispatch_queue_t queue = dispatch_get_main_queue();

    void (^readPID)(void (^)(int)) = ^(void (^done)(int)) {
        if (gGetPID != NULL) {
            gGetPID(queue, ^(int pid) { done(pid); });
        } else {
            done(0);
        }
    };

    readPID(^(int pidBefore) {
        gGetInfo(queue, ^(CFDictionaryRef rawInfo) {
            NSDictionary *info = rawInfo != NULL ? [(__bridge NSDictionary *)rawInfo copy] : @{};
            double rate = doubleValue(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);

            void (^finish)(BOOL) = ^(BOOL playing) {
                readPID(^(int pidAfter) {
                    if (pidAfter != pidBefore && attempt < 2) {
                        performRefresh(attempt + 1);
                        return;
                    }
                    emitInfo(info, playing, pidAfter);
                    finishRefresh();
                });
            };

            if (gGetIsPlaying != NULL) {
                gGetIsPlaying(queue, ^(Boolean isPlaying) {
                    finish(isPlaying || rate > 0);
                });
            } else {
                finish(rate > 0);
            }
        });
    });
}

static void refreshNow(void) {
    if (gGetInfo == NULL) {
        emitJSON(@{ @"type": @"info", @"empty": @YES });
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // Если MediaRemote почему-то не ответил за 2 секунды, не ждём его вечно.
    if (gRefreshInFlight && now - gRefreshStarted < 2.0) {
        gRefreshPending = YES;
        return;
    }
    gRefreshInFlight = YES;
    gRefreshStarted = now;
    performRefresh(0);
}

static void scheduleRefresh(void) {
    if (gRefreshScheduled) {
        return;
    }
    gRefreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        gRefreshScheduled = NO;
        refreshNow();
    });
}

static void handleCommand(NSString *line) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return;
    }
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@" "];
    NSString *name = parts.firstObject;

    if ([name isEqualToString:@"refresh"]) {
        refreshNow();
        return;
    }
    if ([name isEqualToString:@"seek"]) {
        if (parts.count > 1 && gSetElapsed != NULL) {
            gSetElapsed([parts[1] doubleValue]);
        }
        scheduleRefresh();
        return;
    }

    int command = -1;
    if ([name isEqualToString:@"play"]) command = 0;
    else if ([name isEqualToString:@"pause"]) command = 1;
    else if ([name isEqualToString:@"toggle"]) command = 2;
    else if ([name isEqualToString:@"next"]) command = 4;
    else if ([name isEqualToString:@"prev"]) command = 5;

    if (command >= 0 && gSendCommand != NULL) {
        gSendCommand(command, NULL);
    }
    scheduleRefresh();
}

static void startReadingInput(void) {
    gInputBuffer = [NSMutableData data];
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
    input.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (chunk.length == 0) {
            // stdin закрыт — Cool Notch завершился, уходим и мы.
            exit(0);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [gInputBuffer appendData:chunk];
            while (YES) {
                NSRange found = [gInputBuffer rangeOfData:newline options:0 range:NSMakeRange(0, gInputBuffer.length)];
                if (found.location == NSNotFound) {
                    break;
                }
                NSData *lineData = [gInputBuffer subdataWithRange:NSMakeRange(0, found.location)];
                [gInputBuffer replaceBytesInRange:NSMakeRange(0, found.location + 1) withBytes:NULL length:0];
                NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                if (line != nil) {
                    handleCommand(line);
                }
            }
        });
    };
}

static void loadMediaRemote(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (handle == NULL) {
        return;
    }
    gGetInfo = (MRGetNowPlayingInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    gGetIsPlaying = (MRGetIsPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    gGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    gRegister = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    gSendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
    gSetElapsed = (MRSetElapsedTimeFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
}

/// Точка входа. Вызывается из perl как XSUB, поэтому принимает (интерпретатор, CV) и не использует их.
__attribute__((visibility("default")))
void coolnotch_bridge_run(void *interpreter, void *cv) {
    (void)interpreter;
    (void)cv;

    @autoreleasepool {
        loadMediaRemote();
        if (gRegister != NULL) {
            gRegister(dispatch_get_main_queue());
        }

        NSArray<NSString *> *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                (void)note;
                scheduleRefresh();
            }];
        }

        // Страховка на случай, если какое-то уведомление не пришло.
        NSTimer *timer = [NSTimer timerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) {
            (void)t;
            refreshNow();
        }];
        timer.tolerance = 1.5;
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

        startReadingInput();
        emitJSON(@{ @"type": @"ready" });
        refreshNow();
    }

    CFRunLoopRun();
    exit(0);
}
