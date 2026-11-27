//
//  PGPrefs.h
//  GrabberCard
//
//  Shared preference store for the tweak and the Settings bundle.
//

#import <Foundation/Foundation.h>

#define kGrabberCardPrefChangedNotification @"com.grabbercard.prefs.changed"

FOUNDATION_EXPORT NSString *PGPrefPath(void);
FOUNDATION_EXPORT NSDictionary *PGAllPrefs(void);
FOUNDATION_EXPORT id PGGetPref(NSString *key, id fallback);
FOUNDATION_EXPORT BOOL PGGetBool(NSString *key, BOOL fallback);
FOUNDATION_EXPORT CGFloat PGGetFloat(NSString *key, CGFloat fallback);
FOUNDATION_EXPORT NSInteger PGGetInt(NSString *key, NSInteger fallback);
FOUNDATION_EXPORT void PGSetPref(NSString *key, id value);
FOUNDATION_EXPORT void PGRemoveAllPrefs(void);
FOUNDATION_EXPORT void PGPostPrefsChanged(void);
/* 清空内存缓存，下次读取时重新解析 plist（偏好变更通知里调用） */
FOUNDATION_EXPORT void PGInvalidatePrefsCache(void);

/* default values used by both sides */
FOUNDATION_EXPORT NSDictionary *PGDefaultPrefs(void);
