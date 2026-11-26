//
//  PGPrefs.m
//  GrabberCard
//

#import "PGPrefs.h"
#import <notify.h>

NSDictionary *PGDefaultPrefs(void) {
    static NSDictionary *defaults = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = @{
            @"enabled"            : @YES,
            @"cardScale"          : @1.0,
            @"cardWidth"          : @356,
            @"cardHeight"         : @246,
            @"cornerRadius"       : @24,
            @"opacity"            : @0.92,
            @"backgroundStyle"    : @0,     // 0 = 毛玻璃, 1 = 磨砂, 2 = 高斯模糊
            @"sliderHaptic"       : @YES,
            @"use24Hour"          : @YES,
            @"fontScale"          : @1.0,
            @"fontWeight"         : @2,     // 0 regular 1 medium 2 semibold 3 bold
            @"presentHaptic"      : @YES,
            @"longPressControls"  : @YES,
            @"showLyrics"         : @YES,
        };
    });
    return defaults;
}

NSString *PGPrefPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *candidates = @[
            @"/var/mobile/Library/Preferences/com.grabbercard.plist",
        ];
        for (NSString *p in candidates) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { path = p; break; }
        }
        if (!path) path = candidates[0];
    });
    return path;
}

static NSMutableDictionary *PGLoadDictionary(void) {
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:PGPrefPath()];
    NSMutableDictionary *merged = [PGDefaultPrefs() mutableCopy];
    if (raw) {
        for (NSString *key in raw) {
            if (!raw[key]) continue;
            merged[key] = raw[key];
        }
    }
    return merged;
}

static id PGPrefsLock(void) {
    static id lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSObject alloc] init]; });
    return lock;
}

NSDictionary *PGAllPrefs(void) {
    @synchronized (PGPrefsLock()) {
        return [PGLoadDictionary() copy];
    }
}

id PGGetPref(NSString *key, id fallback) {
    if (!key) return fallback;
    NSDictionary *all = PGAllPrefs();
    id value = all[key];
    return value ?: fallback;
}

BOOL PGGetBool(NSString *key, BOOL fallback) {
    id v = PGGetPref(key, nil);
    if (!v) return fallback;
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return fallback;
}

CGFloat PGGetFloat(NSString *key, CGFloat fallback) {
    id v = PGGetPref(key, nil);
    if (!v) return fallback;
    if ([v respondsToSelector:@selector(doubleValue)]) return (CGFloat)[v doubleValue];
    return fallback;
}

NSInteger PGGetInt(NSString *key, NSInteger fallback) {
    id v = PGGetPref(key, nil);
    if (!v) return fallback;
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return fallback;
}

void PGSetPref(NSString *key, id value) {
    if (!key) return;
    NSString *path = PGPrefPath();
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSMutableDictionary *prefs = [[NSMutableDictionary alloc] initWithDictionary:PGDefaultPrefs()];
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:path];
    if (raw) {
        for (NSString *k in raw) {
            if (!raw[k]) continue;
            prefs[k] = raw[k];
        }
    }
    if (value) prefs[key] = value; else [prefs removeObjectForKey:key];

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:prefs
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data) {
        [data writeToFile:path atomically:YES];
    }
}

void PGRemoveAllPrefs(void) {
    [[NSFileManager defaultManager] removeItemAtPath:PGPrefPath() error:nil];
}

void PGPostPrefsChanged(void) {
    notify_post("com.grabbercard.prefs.changed");
}

