// MediaBridge — помощник Cool Notch для чтения системного «Что играет».
//
// Начиная с macOS 15.4 Apple отдаёт данные Now Playing (MediaRemote) только
// своим процессам. Поэтому Cool Notch запускает системный /usr/bin/perl, тот
// загружает эту библиотеку и вызывает coolnotch_bridge_run(). Дальше библиотека:
//   • пишет в stdout по одной JSON-строке на каждое изменение трека;
//   • читает из stdin команды: play, pause, toggle, stop, next, prev, seek <сек>, refresh;
//   • завершается, когда закрывается stdin (то есть когда закрылся Cool Notch).
//
// Так чёлка видит любой плеер: приложение Яндекс Музыки, браузер, Spotify и т. д.
// Пользователь может выключить это в настройках Cool Notch.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*MRGetNowPlayingInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedTimeFn)(double);
// Чтение всех клиентов «Что играет», а не только выбранного системой
// (см. github.com/ungive/mediaremote-adapter/issues/41 — так же вызывается и там).
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef void *(*MRGetLocalOriginFn)(void);
typedef void (*MRGetInfoForPlayerFn)(id, void *, dispatch_queue_t, void (^)(NSDictionary *, NSError *));

static MRGetNowPlayingInfoFn gGetInfo = NULL;
static MRGetIsPlayingFn gGetIsPlaying = NULL;
static MRGetPIDFn gGetPID = NULL;
static MRRegisterFn gRegister = NULL;
static MRSendCommandFn gSendCommand = NULL;
static MRSetElapsedTimeFn gSetElapsed = NULL;
static MRGetClientsFn gGetClients = NULL;
static MRGetLocalOriginFn gGetLocalOrigin = NULL;
static MRGetInfoForPlayerFn gGetInfoForPlayer = NULL;
/// Включается переменной окружения COOLNOTCH_ALL_CLIENTS=1. Если в этом режиме помощник
/// упадёт, Cool Notch перезапустит его без неё (см. MediaBridgeProcess).
static BOOL gAllClients = NO;
static BOOL gClientsInFlight = NO;
static CFAbsoluteTime gClientsStarted = 0;
static NSMutableDictionary<NSString *, NSString *> *gClientArtworkKeys = nil;

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

/// Данные одного клиента (не выбранного системой плеера) для сообщения "clients".
static NSDictionary *clientPayload(NSDictionary *info, NSString *bundle, NSNumber *pid) {
    NSString *title = stringValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    if (title.length == 0) {
        return nil;
    }
    NSString *artist = stringValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    NSString *album = stringValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    double time = [timestamp isKindOfClass:[NSDate class]]
        ? [(NSDate *)timestamp timeIntervalSince1970]
        : [[NSDate date] timeIntervalSince1970];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"bundle"] = bundle;
    out[@"pid"] = pid ?: @0;
    out[@"title"] = title;
    out[@"artist"] = artist;
    out[@"album"] = album;
    out[@"duration"] = @(doubleValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]));
    out[@"elapsed"] = @(doubleValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]));
    out[@"rate"] = @(doubleValue(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]));
    out[@"timestamp"] = @(time);

    id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:[NSData class]] && [(NSData *)artwork length] > 0) {
        NSData *artworkData = (NSData *)artwork;
        out[@"hasArtwork"] = @YES;
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%lu", title, artist, album, (unsigned long)artworkData.length];
        if (![key isEqualToString:gClientArtworkKeys[bundle]]) {
            gClientArtworkKeys[bundle] = key;
            out[@"artwork"] = [artworkData base64EncodedStringWithOptions:0];
        }
    } else {
        out[@"hasArtwork"] = @NO;
        [gClientArtworkKeys removeObjectForKey:bundle];
    }
    return out;
}

/// Все приложения, которые сейчас сообщают системе о воспроизведении. macOS отдаёт команды
/// только выбранному, но прочитать можно каждое — так чёлка видит, например, Яндекс Музыку,
/// даже когда «главным» система считает браузер.
static void refreshClients(void) {
    if (!gAllClients || gGetClients == NULL || gGetLocalOrigin == NULL || gGetInfoForPlayer == NULL) {
        return;
    }
    // Предыдущий запрос ещё идёт — ждём, но не дольше 4 секунд (вдруг MediaRemote не ответил).
    if (gClientsInFlight && CFAbsoluteTimeGetCurrent() - gClientsStarted < 4) {
        return;
    }
    Class pathClass = NSClassFromString(@"MRPlayerPath");
    SEL initSelector = NSSelectorFromString(@"initWithOrigin:client:player:");
    if (pathClass == Nil || ![pathClass instancesRespondToSelector:initSelector]) {
        return;
    }
    gClientsInFlight = YES;
    gClientsStarted = CFAbsoluteTimeGetCurrent();
    dispatch_queue_t queue = dispatch_get_main_queue();
    gGetClients(queue, ^(CFArrayRef raw) {
        NSArray *clients = raw != NULL ? [(__bridge NSArray *)raw copy] : @[];
        id origin = (__bridge id)gGetLocalOrigin();
        NSMutableArray *items = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();

        for (id client in clients) {
            if (![client respondsToSelector:@selector(bundleIdentifier)]) {
                continue;
            }
            id bundle = [client valueForKey:@"bundleIdentifier"];
            if (![bundle isKindOfClass:[NSString class]] || [(NSString *)bundle length] == 0) {
                continue;
            }
            NSNumber *pid = @0;
            if ([client respondsToSelector:@selector(processIdentifier)]) {
                id value = [client valueForKey:@"processIdentifier"];
                if ([value isKindOfClass:[NSNumber class]]) {
                    pid = value;
                }
            }
            id path = ((id (*)(id, SEL, id, id, id))objc_msgSend)([pathClass alloc], initSelector, origin, client, nil);
            if (path == nil) {
                continue;
            }
            dispatch_group_enter(group);
            gGetInfoForPlayer(path, NULL, queue, ^(NSDictionary *info, NSError *error) {
                (void)error;
                if ([info isKindOfClass:[NSDictionary class]] && info.count > 0) {
                    NSDictionary *item = clientPayload(info, (NSString *)bundle, pid);
                    if (item != nil) {
                        [items addObject:item];
                    }
                }
                dispatch_group_leave(group);
            });
        }

        // Если кто-то из клиентов не ответил за 2 секунды — отправляем то, что есть.
        __block BOOL sent = NO;
        void (^send)(void) = ^{
            if (sent) {
                return;
            }
            sent = YES;
            gClientsInFlight = NO;
            emitJSON(@{ @"type": @"clients", @"items": [items copy] });
        };
        dispatch_group_notify(group, queue, send);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), queue, send);
    });
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
    refreshClients();
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
    else if ([name isEqualToString:@"stop"]) command = 3;
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
    gGetClients = (MRGetClientsFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClients");
    gGetLocalOrigin = (MRGetLocalOriginFn)dlsym(handle, "MRMediaRemoteGetLocalOrigin");
    gGetInfoForPlayer = (MRGetInfoForPlayerFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer");
}

/// Точка входа. Вызывается из perl как XSUB, поэтому принимает (интерпретатор, CV) и не использует их.
__attribute__((visibility("default")))
void coolnotch_bridge_run(void *interpreter, void *cv) {
    (void)interpreter;
    (void)cv;

    @autoreleasepool {
        const char *allClients = getenv("COOLNOTCH_ALL_CLIENTS");
        gAllClients = allClients != NULL && strcmp(allClients, "1") == 0;
        gClientArtworkKeys = [NSMutableDictionary dictionary];
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
        NSTimer *timer = [NSTimer timerWithTimeInterval:(gAllClients ? 3 : 5) repeats:YES block:^(NSTimer *t) {
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
