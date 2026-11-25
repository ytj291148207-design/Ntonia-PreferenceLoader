#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PGGrabberOverlayView.h"
#import "PGNowPlaying.h"
#import "PerfectGrabberPreferences.h"

extern "C" void PGDebugLog(NSString *format, ...);
static NSString *const PGLogPath = @"/var/mobile/Media/PerfectGrabber.log";
static NSLock *PGLogLock;
void PGDebugLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    static dispatch_once_t once; dispatch_once(&once, ^{ PGLogLock = [NSLock new]; });
    [PGLogLock lock];
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:PGLogPath]) [fm createFileAtPath:PGLogPath contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:PGLogPath];
        [handle seekToEndOfFile];
        [handle writeData:[[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } @catch (__unused NSException *exception) { }
    [PGLogLock unlock];
}

static UIView *PGTongueView(id grabber) {
    for (NSString *name in @[@"_tongueContainer", @"_tongueBackdropView", @"_containingView"]) {
        Ivar ivar = class_getInstanceVariable(object_getClass(grabber), name.UTF8String);
        id value = ivar ? object_getIvar(grabber, ivar) : nil;
        if (![value isKindOfClass:UIView.class]) {
            @try { value = [grabber valueForKey:name]; }
            @catch (__unused NSException *exception) { value = nil; }
        }
        if ([value isKindOfClass:UIView.class]) return value;
    }
    return [grabber isKindOfClass:UIView.class] ? grabber : nil;
}

static UIView *PGTongueChevron(id grabber) {
    Ivar ivar = class_getInstanceVariable(object_getClass(grabber), "_tongueChevron");
    id value = ivar ? object_getIvar(grabber, ivar) : nil;
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static BOOL PGIsTopEdgeGrabber(id grabber) {
    for (NSString *key in @[@"edge", @"grabberEdge", @"screenEdge", @"edgeLocation", @"displayEdge"]) {
        @try {
            id value = [grabber valueForKey:key];
            if ([value respondsToSelector:@selector(integerValue)]) {
                NSInteger edge = [value integerValue];
                if (edge == UIRectEdgeTop) return YES;
                if (edge == UIRectEdgeBottom) return NO;
            }
        } @catch (__unused NSException *exception) { }
    }
    UIView *view = PGTongueView(grabber);
    UIWindow *window = view.window;
    if (view && window) {
        CGRect rect = [view convertRect:view.bounds toView:window];
        return CGRectGetMinY(rect) < CGRectGetHeight(window.bounds) - CGRectGetMaxY(rect);
    }
    return YES;
}

#pragma mark - Fixed card in the original SpringBoard window

@interface PGEdgeCardContainer : UIView
@property (nonatomic, weak) PGGrabberOverlayView *card;
@property (nonatomic, copy) void (^onLayout)(void);
@property (nonatomic, assign) CGSize previousSize;
@end
@implementation PGEdgeCardContainer
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (!CGSizeEqualToSize(size, self.previousSize)) {
        self.previousSize = size;
        if (self.onLayout) self.onLayout();
    }
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    PGGrabberOverlayView *card = self.card;
    if (self.hidden || !card || card.hidden || !card.userInteractionEnabled) return nil;
    CGPoint cardPoint = [card convertPoint:point fromView:self];
    if (![card pointInside:cardPoint withEvent:event]) return nil;
    return [card hitTest:cardPoint withEvent:event];
}
@end

@interface PGEdgeCardHost : NSObject
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIView *sourceHost;
@property (nonatomic, weak) UIView *chevron;
@property (nonatomic, strong) NSValue *anchorInWindow;
@property (nonatomic, strong) PGEdgeCardContainer *container;
@property (nonatomic, strong) PGGrabberOverlayView *card;
@property (nonatomic, assign) BOOL originalChevronHidden;
@property (nonatomic, assign) BOOL savedChevronState;
+ (instancetype)sharedHost;
- (void)showForHostView:(UIView *)host chevron:(nullable UIView *)chevron;
- (void)hide;
- (void)refresh;
@end

@implementation PGEdgeCardHost
+ (instancetype)sharedHost {
    static PGEdgeCardHost *instance; static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; }); return instance;
}

- (void)showForHostView:(UIView *)host chevron:(UIView *)chevron {
    UIWindow *window = host.window;
    if (!window) return;
    if (self.container && self.window != window) [self hide];
    self.window = window;
    self.sourceHost = host;
    if (chevron && self.chevron != chevron) {
        if (self.chevron && self.savedChevronState) self.chevron.hidden = self.originalChevronHidden;
        self.chevron = chevron;
        self.originalChevronHidden = chevron.hidden;
        self.savedChevronState = YES;
    } else if (!self.chevron && chevron) {
        self.chevron = chevron;
        self.originalChevronHidden = chevron.hidden;
        self.savedChevronState = YES;
    }
    UIView *anchor = chevron ?: host;
    self.anchorInWindow = [NSValue valueWithCGRect:[anchor convertRect:anchor.bounds toView:window]];

    if (!self.container) {
        PGEdgeCardContainer *container = [[PGEdgeCardContainer alloc] initWithFrame:window.bounds];
        container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        container.backgroundColor = UIColor.clearColor;
        container.userInteractionEnabled = YES;
        self.container = container;
        self.card = [[PGGrabberOverlayView alloc] initWithFrame:CGRectZero];
        container.card = self.card;
        [container addSubview:self.card];
        __weak typeof(self) weakSelf = self;
        container.onLayout = ^{ [weakSelf refresh]; };
        self.card.onClose = ^{ [weakSelf hide]; };
        self.card.onHeightChange = ^(__unused CGFloat height) { [weakSelf refresh]; };
        // Use the original grabber's SpringBoard window and orientation. This is
        // a fixed screen-edge view, not a separate UIWindow or a draggable HUD.
        [window addSubview:container];
    }
    if (self.chevron) self.chevron.hidden = YES;
    [window bringSubviewToFront:self.container];
    [self.card startUpdating];
    [self refresh];
    if (PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
}

- (void)refresh {
    UIWindow *window = self.window;
    PGEdgeCardContainer *container = self.container;
    PGGrabberOverlayView *card = self.card;
    if (!window || !container || !card) return;
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (!preferences.isEnabled) { [self hide]; return; }

    CGRect bounds = window.bounds;
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat inset = MAX(8.0, MAX(safe.left, safe.right));
    CGFloat maxWidth = MAX(220.0, CGRectGetWidth(bounds) - inset * 2.0);
    CGFloat width = MIN(maxWidth, MAX(220.0, preferences.cardWidth));
    card.cardScale = preferences.cardScale;
    card.blurAmount = preferences.cardBlur;
    card.backgroundOpacity = preferences.cardOpacity;
    card.cornerRadius = preferences.cardCornerRadius;
    CGFloat height = [card heightForWidth:width];

    // Keep aligned to the system capsule when it exists; after pull-down dismissal
    // keep the same view at the physical top-center edge of this same window.
    CGRect anchor = CGRectZero;
    UIView *anchorView = self.chevron;
    if (anchorView.window == window) {
        anchor = [anchorView convertRect:anchorView.bounds toView:window];
        self.anchorInWindow = [NSValue valueWithCGRect:anchor];
    } else if (self.anchorInWindow) {
        anchor = self.anchorInWindow.CGRectValue;
    }
    CGFloat top = CGRectIsEmpty(anchor) ? CGRectGetMinY(bounds) + safe.top : CGRectGetMinY(anchor);
    top = MIN(MAX(CGRectGetMinY(bounds), top), MAX(CGRectGetMinY(bounds), CGRectGetMaxY(bounds) - height));
    CGFloat centerX = CGRectIsEmpty(anchor) ? CGRectGetMidX(bounds) : CGRectGetMidX(anchor);
    CGFloat left = MAX(CGRectGetMinX(bounds) + inset,
                       MIN(centerX - width * 0.5, CGRectGetMaxX(bounds) - inset - width));
    container.frame = bounds;
    card.frame = CGRectMake(left, top, width, height);
    [card setNeedsLayout];
}

- (void)hide {
    [self.card stopUpdating];
    [self.container removeFromSuperview];
    if (self.chevron && self.savedChevronState) self.chevron.hidden = self.originalChevronHidden;
    self.card = nil;
    self.container = nil;
    self.window = nil;
    self.sourceHost = nil;
    self.chevron = nil;
    self.anchorInWindow = nil;
    self.savedChevronState = NO;
}
@end

static void PGPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PerfectGrabberPreferences.sharedPreferences reload];
        if (!PerfectGrabberPreferences.sharedPreferences.isEnabled) {
            [[PGEdgeCardHost sharedHost] hide]; return;
        }
        [[PGEdgeCardHost sharedHost] refresh];
    });
}

%group PerfectGrabberHooks
%hook SBGrabberTongue
- (void)_willPresent {
    %orig;
    [PerfectGrabberPreferences.sharedPreferences reload];
    if (!PerfectGrabberPreferences.sharedPreferences.isEnabled || !PGIsTopEdgeGrabber(self)) {
        [[PGEdgeCardHost sharedHost] hide]; return;
    }
    UIView *host = PGTongueView(self);
    if (host.window) [[PGEdgeCardHost sharedHost] showForHostView:host chevron:PGTongueChevron(self)];
}
- (void)_willDismiss {
    // Leave the same fixed, top-center card visible after the pull-down closes.
    [[PGEdgeCardHost sharedHost] refresh];
    %orig;
}
%end
%end

%ctor {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        Class cls = NSClassFromString(@"SBGrabberTongue");
        if (cls && class_getInstanceMethod(cls, @selector(_willPresent)) &&
            class_getInstanceMethod(cls, @selector(_willDismiss))) {
            %init(PerfectGrabberHooks, SBGrabberTongue = cls);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [PerfectGrabberPreferences.sharedPreferences reload];
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                            PGPreferencesChanged,
                                            (__bridge CFStringRef)PGPreferencesChangedNotification,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        });
    }
}
