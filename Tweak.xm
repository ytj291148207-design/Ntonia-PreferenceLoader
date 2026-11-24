#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PGGrabberHUDView.h"
#import "PGGrabberLandscapeBar.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"

static const void *PGOverlayAssociationKey = &PGOverlayAssociationKey;
static const void *PGHUDAssociationKey = &PGHUDAssociationKey;
static const void *PGLongPressDismissGuardKey = &PGLongPressDismissGuardKey;
static __weak id PGActiveOverlayGrabber;
static __weak id PGActiveHUDGrabber;

static id PGObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (ivar) return object_getIvar(object, ivar);

    @try {
        return [object valueForKey:[NSString stringWithUTF8String:name]];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIView *PGFirstView(id grabber, NSArray<NSString *> *ivarNames) {
    for (NSString *name in ivarNames) {
        id candidate = PGObjectIvar(grabber, name.UTF8String);
        if ([candidate isKindOfClass:UIView.class]) return candidate;
    }
    return nil;
}

static UIView *PGTongueView(id grabber) {
    UIView *view = PGFirstView(grabber, @[@"_tongueContainer", @"_tongueBackdropView", @"_containingView"]);
    return view ?: ([grabber isKindOfClass:UIView.class] ? grabber : nil);
}

static void PGHideChevron(id grabber) {
    UIView *chevron = PGFirstView(grabber, @[@"_tongueChevron"]);
    if (chevron) chevron.hidden = YES;
}

static BOOL PGIsSwipeUpGrabber(id grabber) {
    // Edge fields are scalar enums on some iOS builds. Use KVC so scalars are boxed
    // instead of reading them through object_getIvar as if they were Objective-C objects.
    for (NSString *key in @[@"edge", @"grabberEdge", @"screenEdge", @"edgeLocation", @"displayEdge"]) {
        id value = nil;
        @try {
            value = [grabber valueForKey:key];
        } @catch (__unused NSException *exception) {
            value = nil;
        }
        if (![value respondsToSelector:@selector(integerValue)]) continue;
        NSInteger edge = [value integerValue];
        if (edge == UIRectEdgeBottom) return YES;
        if (edge == UIRectEdgeTop) return NO;
    }

    NSArray<NSString *> *names = @[@"_tongueBackdropView", @"_tongueChevron", @"_tongueContainer",
                                   @"_containingView"];
    for (NSString *name in names) {
        UIView *marker = PGFirstView(grabber, @[name]);
        UIWindow *window = marker.window;
        if (!marker || !window) continue;
        CGRect markerFrame = [marker convertRect:marker.bounds toView:window];
        CGFloat topDistance = CGRectGetMinY(markerFrame);
        CGFloat bottomDistance = CGRectGetHeight(window.bounds) - CGRectGetMaxY(markerFrame);
        if (bottomDistance + 20.0 < topDistance) return YES;
        if (topDistance + 20.0 < bottomDistance) return NO;
    }

    if ([grabber isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)grabber;
        UIWindow *window = view.window;
        if (window) {
            CGRect frame = [view convertRect:view.bounds toView:window];
            CGFloat topDistance = CGRectGetMinY(frame);
            CGFloat bottomDistance = CGRectGetHeight(window.bounds) - CGRectGetMaxY(frame);
            if (bottomDistance + 20.0 < topDistance) return YES;
        }
    }
    return NO;
}

static void PGLayoutOverlay(id grabber, PGGrabberOverlayView *overlay) {
    UIView *host = overlay.superview;
    if (!host) return;
    overlay.frame = host.bounds;
    overlay.layer.cornerRadius = MIN(12.0, CGRectGetHeight(host.bounds) / 2.0);
}

static PGGrabberOverlayView *PGOverlayForGrabber(id grabber, BOOL create) {
    PGGrabberOverlayView *overlay = objc_getAssociatedObject(grabber, PGOverlayAssociationKey);
    if (!overlay && create) {
        UIView *host = PGTongueView(grabber);
        if (!host) return nil;
        overlay = [[PGGrabberOverlayView alloc] initWithFrame:CGRectZero];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:overlay];
        PGHideChevron(grabber);
        PGLayoutOverlay(grabber, overlay);
        objc_setAssociatedObject(grabber, PGOverlayAssociationKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return overlay;
}

static void PGHideOverlay(id grabber);
static void PGHideHUD(id grabber);

static void PGShowOverlay(id grabber) {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (!preferences.isEnabled) return;
    if (!preferences.showOnSwipeUp && PGIsSwipeUpGrabber(grabber)) return;

    if (PGActiveHUDGrabber && PGActiveHUDGrabber != grabber) PGHideHUD(PGActiveHUDGrabber);
    PGActiveOverlayGrabber = grabber;

    PGGrabberOverlayView *overlay = PGOverlayForGrabber(grabber, YES);
    if (!overlay) return;
    PGHideChevron(grabber);
    PGLayoutOverlay(grabber, overlay);
    dispatch_async(dispatch_get_main_queue(), ^{
        PGLayoutOverlay(grabber, overlay);
    });
    overlay.hidden = NO;
    overlay.alpha = 1.0;
    overlay.userInteractionEnabled = YES;
    __weak id weakGrabber = grabber;
    overlay.onMusicLongPress = ^{
        id strongGrabber = weakGrabber;
        if (!strongGrabber) return;
        // Keep dismissal suppressed for the whole hold, regardless of how long it lasts.
        objc_setAssociatedObject(strongGrabber, PGLongPressDismissGuardKey, @(-1.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [PGLandscapeBar.sharedBar showControlPanelForPullDown];
    };
    overlay.onMusicLongPressEnded = ^{
        id strongGrabber = weakGrabber;
        if (!strongGrabber) return;
        // Let SpringBoard's delayed finger-up dismissal finish before releasing the guard.
        CFTimeInterval expiry = CACurrentMediaTime() + 1.5;
        objc_setAssociatedObject(strongGrabber, PGLongPressDismissGuardKey, @(expiry), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    [overlay deferAncestorTapRecognizersToAllowLongPress];
    [overlay startUpdating];
    if (preferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
}

static void PGHideOverlay(id grabber) {
    PGGrabberOverlayView *overlay = PGOverlayForGrabber(grabber, NO);
    [overlay stopUpdating];
    [overlay removeFromSuperview];
    objc_setAssociatedObject(grabber, PGOverlayAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (PGActiveOverlayGrabber == grabber) PGActiveOverlayGrabber = nil;
}

static void PGHideHUD(id grabber) {
    PGGrabberHUDView *hud = objc_getAssociatedObject(grabber, PGHUDAssociationKey);
    if (!hud) return;
    [hud stopUpdating];
    [hud removeFromSuperview];
    objc_setAssociatedObject(grabber, PGHUDAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (PGActiveHUDGrabber == grabber) PGActiveHUDGrabber = nil;
}

static void PGShowHUD(id grabber) {
    PGGrabberHUDView *hud = objc_getAssociatedObject(grabber, PGHUDAssociationKey);
    UIView *tongue = PGTongueView(grabber);
    UIWindow *window = tongue.window;
    if (!window) return;
    if (PGActiveOverlayGrabber && PGActiveOverlayGrabber != grabber) PGHideOverlay(PGActiveOverlayGrabber);
    PGActiveHUDGrabber = grabber;
    if (!hud) {
        hud = [[PGGrabberHUDView alloc] initWithFrame:window.bounds];
        hud.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        hud.userInteractionEnabled = NO;
        [window addSubview:hud];
        objc_setAssociatedObject(grabber, PGHUDAssociationKey, hud, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    hud.frame = window.bounds;
    [window bringSubviewToFront:hud];
    [hud startUpdating];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(grabber, PGHUDAssociationKey) == hud) {
            PGHideHUD(grabber);
        }
    });
}

%group PerfectGrabberHooks

%hook SBGrabberTongue

- (void)_willPresent {
    %orig;
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    [preferences reload];
    // 下拉面板自己会显示时间电量，横屏常驻块先收起，避免两块信息重叠。
    [PGLandscapeBar.sharedBar setSuspended:YES];
    if (!preferences.isEnabled) return;
    BOOL swipeUp = PGIsSwipeUpGrabber(self);
    if (swipeUp) {
        PGHideOverlay(self);
        if (preferences.showOnSwipeUp) PGShowHUD(self);
        return;
    }
    PGHideHUD(self);
    PGShowOverlay(self);
}

- (void)_willDismiss {
    NSNumber *guard = objc_getAssociatedObject(self, PGLongPressDismissGuardKey);
    BOOL holdInProgress = guard && guard.doubleValue < 0.0;
    BOOL fingerUpGrace = guard && guard.doubleValue >= 0.0 && CACurrentMediaTime() < guard.doubleValue;
    if (holdInProgress || fingerUpGrace) {
        // Some iOS builds collapse the tongue as soon as the touch ends even after
        // the parent tap recognizer has been deferred. Keep it alive for the panel.
        PGHideChevron(self);
        return;
    }
    objc_setAssociatedObject(self, PGLongPressDismissGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL handled = PGOverlayForGrabber(self, NO) != nil;
    if (handled) {
        PGHideChevron(self);
        PGHideOverlay(self);
    }
    %orig;
    PGHideHUD(self);
    [PGLandscapeBar.sharedBar setSuspended:NO];
    if (handled) {
        PGHideChevron(self);
        dispatch_async(dispatch_get_main_queue(), ^{
            PGHideChevron(self);
        });
    }
}

%end

%end

static void PGPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PerfectGrabberPreferences.sharedPreferences reload];
        [PGLandscapeBar.sharedBar reloadPreferences];
    });
}

#pragma mark - 启动时机与崩溃守卫

// .xm 是按 Objective-C++ 编的，这里必须 extern "C"，否则会被按 C++ 名字改写去找。
extern "C" void PGDebugLog(NSString *format, ...);

/// 启动标记文件。存在 = 上一次 SpringBoard 在启动流程走完之前就死了，
/// 那基本就是本插件的启动路径把它带下来的（就是安全模式）。
static NSString *const PGStartupGuardPath = @"/var/mobile/Media/PerfectGrabber.startup";

/// 领一次启动机会。返回 NO 表示上次崩过，本次先不启动横屏块，让 SpringBoard 能起来。
static BOOL PGStartupGuardClaim(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:PGStartupGuardPath]) {
        [manager removeItemAtPath:PGStartupGuardPath error:NULL];
        return NO;
    }
    [@"started" writeToFile:PGStartupGuardPath atomically:YES
                  encoding:NSUTF8StringEncoding error:NULL];
    return YES;
}

static void PGStartupGuardClear(void) {
    [[NSFileManager defaultManager] removeItemAtPath:PGStartupGuardPath error:NULL];
}

static BOOL PGStartupScheduled = NO;
static BOOL PGStartupAllowed = NO;

/// dyld 阶段（%ctor）里绝对不能碰 SpringBoard 的私有服务。
/// 那时 SBApplicationController / 媒体远控 / 场景管理器都还没初始化，
/// 它们的"查询"函数会把未初始化的全局变量当指针返回 —— 一旦把这个垃圾指针
/// 当 ObjC 对象交给 ARC 去 retain，就是 EXC_BAD_ACCESS（0x10000003 / objc_retain）
/// 加安全模式。所以 %ctor 只登记钩子，真正的工作推迟到 SpringBoard 的 runloop 跑起来之后。
static void PGScheduleStartupWork(void) {
    if (PGStartupScheduled) return;
    PGStartupScheduled = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!PGStartupAllowed) {
            PGDebugLog(@"启动守卫: 上次启动中途崩溃，本次跳过横屏块（下次启动会自动重试）");
            return;
        }

        [PerfectGrabberPreferences.sharedPreferences reload];
        [PGLandscapeBar.sharedBar reloadPreferences];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PGPreferencesChanged,
                                        (__bridge CFStringRef)PGPreferencesChangedNotification,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // 再补一拍：SpringBoard 起来之后场景和前台 App 才第一次有值。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [PGLandscapeBar.sharedBar reloadPreferences];
        });

        // 平安活过这段就认为启动路径没问题，把标记撤掉。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PGStartupGuardClear();
        });
    });
}

%ctor {
    @autoreleasepool {
        if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;
        // 只有这一步是安全的：只是查类与选择子存不存在，不碰任何 SpringBoard 状态。
        Class grabberClass = NSClassFromString(@"SBGrabberTongue");
        if (grabberClass && class_getInstanceMethod(grabberClass, @selector(_willPresent)) &&
            class_getInstanceMethod(grabberClass, @selector(_willDismiss))) {
            %init(PerfectGrabberHooks, SBGrabberTongue = grabberClass);
        }
        // 先领标记再干活：本次启动若崩在下面任何一步，下次启动会看到标记并跳过横屏块。
        PGStartupAllowed = PGStartupGuardClaim();
        PGScheduleStartupWork();
    }
}
