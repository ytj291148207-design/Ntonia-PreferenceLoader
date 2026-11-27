//
//  PGPrefs.m
//  GrabberCard
//
//  偏好存取：内存缓存 + 文件 mtime 校验。
//  旧实现每读一个键都把 plist 从磁盘读一遍并解析一次，卡片每 0.5 秒刷新时
//  会有十几次 fontScale / fontWeight 读取，全是磁盘 IO，这里改成缓存。
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

#pragma mark - 缓存

static id PGPrefsLockObject(void) {
    static id lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSObject alloc] init]; });
    return lock;
}

static NSMutableDictionary *PGCachedPrefs = nil;
static NSDate *PGCachedMtime = nil;
static NSTimeInterval PGLastCacheCheck = 0;

void PGInvalidatePrefsCache(void) {
    @synchronized (PGPrefsLockObject()) {
        PGCachedPrefs = nil;
        PGCachedMtime = nil;
        PGLastCacheCheck = 0;
    }
}

static NSDate *PGCurrentFileMtime(void) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:PGPrefPath() error:nil];
    return attrs[NSFileModificationDate];
}

// 最多每 0.25 秒 stat 一次文件；命中缓存时直接返回内存里的字典。
static void PGEnsurePrefsCache(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (PGCachedPrefs && (now - PGLastCacheCheck) < 0.25) return;
    PGLastCacheCheck = now;

    NSDate *mtime = PGCurrentFileMtime();
    if (PGCachedPrefs) {
        if (!mtime && !PGCachedMtime) return;      // 文件一直不存在
        if (mtime && PGCachedMtime && [mtime isEqualToDate:PGCachedMtime]) return;
    }

    NSMutableDictionary *merged = [PGDefaultPrefs() mutableCopy];
    NSDictionary *raw = [NSDictionary dictionaryWithContentsOfFile:PGPrefPath()];
    if (raw) {
        for (NSString *key in raw) {
            if (!raw[key]) continue;
            merged[key] = raw[key];
        }
    }
    PGCachedPrefs = merged;
    PGCachedMtime = mtime;
}

#pragma mark - 读取

NSDictionary *PGAllPrefs(void) {
    @synchronized (PGPrefsLockObject()) {
        PGEnsurePrefsCache();
        return [PGCachedPrefs copy];
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

#pragma mark - 写入

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
        @synchronized (PGPrefsLockObject()) {
            PGCachedPrefs = [prefs mutableCopy];
            PGCachedMtime = PGCurrentFileMtime();
            PGLastCacheCheck = [NSDate timeIntervalSinceReferenceDate];
        }
    }
}

void PGRemoveAllPrefs(void) {
    [[NSFileManager defaultManager] removeItemAtPath:PGPrefPath() error:nil];
    PGInvalidatePrefsCache();
}

void PGPostPrefsChanged(void) {
    // notify_post 要的是 C 字符串，不能用 NSString 字面量。
    notify_post("com.grabbercard.prefs.changed");
}
