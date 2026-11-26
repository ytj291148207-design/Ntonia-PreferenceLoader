#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "PGGrabberOverlayView.h"
#import "PGNowPlaying.h"
#import "PerfectGrabberPreferences.h"

extern "C" void PGDebugLog(NSString *format, ...);
static NSString *const PGLogPath = @"/var/mobile/Media/PerfectGrabber.log";
static NSLock *PGLogLock;
static const void *PGPinnedCardGuardKey = &PGPinnedCardGuardKey;

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
            @try { value = [grabber valueForKey:name]; } @catch (__unused NSException *exception) { value = nil; }
        }
        if ([value isKindOfClass:UIView.class]) return value;
    }
    return [grabber isKindOfClass:UIView.class] ? (UIView *)grabber : nil;
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

@interface PGNativeCardHost : NSObject
@property (nonatomic, strong) PGGrabberOverlayView *card;
@property (nonatomic, weak) UIView *host;
@property (nonatomic, weak) UIView *parent;
@property (nonatomic, weak) id grabber;
@property (nonatomic, strong) NSValue *originalFrame;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *clipState;
@property (nonatomic, assign) BOOL holdActive;
@property (nonatomic, assign) BOOL presented;
+ (instancetype)shared;
- (void)showInOriginalHost:(UIView *)host grabber:(id)grabber;
- (void)refresh;
- (void)hide;
@end

@implementation PGNativeCardHost
+ (instancetype)shared {
    static PGNativeCardHost *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (void)saveAndDisableAncestorClipping {
    if (self.clipState || !self.host) return;
    self.clipState = [NSMutableArray array];
    for (UIView *view = self.host.superview; view; view = view.superview) {
        [self.clipState addObject:@{@"view":view, @"clips":@(view.clipsToBounds)}];
        view.clipsToBounds = NO;
        if ([view isKindOfClass:UIWindow.class]) break;
    }
}

- (void)restoreAncestorClipping {
    for (NSDictionary *entry in self.clipState) {
        UIView *view = entry[@"view"];
        if (view) view.clipsToBounds = [entry[@"clips"] boolValue];
    }
    self.clipState = nil;
}

- (CGFloat)preferredWidth {
    CGFloat parentWidth = self.parent ? CGRectGetWidth(self.parent.bounds) : CGRectGetWidth(UIScreen.mainScreen.bounds);
    CGFloat available = MAX(220.0, parentWidth - 12.0);
    return MIN(available, MAX(240.0, PerfectGrabberPreferences.sharedPreferences.cardWidth));
}

- (CGRect)frameForCurrentHost {
    if (!self.host || !self.parent) return CGRectZero;
    CGRect original = self.originalFrame ? self.originalFrame.CGRectValue : self.host.frame;
    CGFloat width = [self preferredWidth];
    CGFloat center = CGRectGetMidX(original);
    CGFloat left = MAX(6.0, MIN(center - width * 0.5, CGRectGetWidth(self.parent.bounds) - width - 6.0));
    CGFloat top = MAX(0.0, CGRectGetMinY(original));
    CGFloat requestedHeight = [self.card heightForWidth:width];
    CGFloat maximumHeight = MAX(44.0, CGRectGetHeight(self.parent.bounds) - top - 2.0);
    CGFloat height = MIN(requestedHeight, maximumHeight);
    return CGRectMake(left, top, width, height);
}

- (void)layoutCardAnimated:(BOOL)animated {
    if (!self.card || !self.host || !self.parent || self.host.superview != self.parent) return;
    CGRect hostFrame = [self frameForCurrentHost];
    void (^layout)(void) = ^{
        self.host.frame = hostFrame;
        self.card.frame = self.host.bounds;
        [self.host bringSubviewToFront:self.card];
        [self.card setNeedsLayout];
        [self.card layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.25 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:layout completion:nil];
    } else {
        layout();
    }
}

- (void)deferHostTapsUntilLongPressFails {
    UILongPressGestureRecognizer *hold = nil;
    for (UIGestureRecognizer *recognizer in self.card.gestureRecognizers) {
        if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) { hold=(UILongPressGestureRecognizer *)recognizer; break; }
    }
    if (!hold) return;
    for (UIView *view=self.host; view; view=view.superview) {
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            if (recognizer != hold && [recognizer isKindOfClass:UITapGestureRecognizer.class])
                [recognizer requireGestureRecognizerToFail:hold];
        }
        if (view == self.parent) break;
    }
}

- (void)showInOriginalHost:(UIView *)host grabber:(id)grabber {
    if (!PerfectGrabberPreferences.sharedPreferences.isEnabled) { [self hide]; return; }
    if (!host || !host.window || !host.superview) return;
    if (self.host != host || !self.originalFrame) self.originalFrame = [NSValue valueWithCGRect:host.frame];
    self.host = host;
    self.parent = host.superview;
    self.grabber = grabber;
    if (!self.card) {
        self.card = [[PGGrabberOverlayView alloc] initWithFrame:host.bounds];
        self.card.compactMode = YES;
        __weak typeof(self) weak = self;
        self.card.onClose = nil; // 右上角按钮收起内容，不关闭插件卡片
        self.card.onHeightChange = ^(CGFloat height) { [weak layoutCardAnimated:YES]; };
        self.card.onCollapseToggle = ^(BOOL collapsed) { [weak layoutCardAnimated:YES]; };
        self.card.onLongPressStateChange = ^(BOOL active) {
            weak.holdActive = active;
            weak.card.deferNativeGrabberDismissal = active;
            if (weak.grabber) objc_setAssociatedObject(weak.grabber, PGPinnedCardGuardKey, active ? @(-1.0) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        };
    }
    if (self.card.superview != host) {
        [self.card removeFromSuperview];
        [host addSubview:self.card];
    }
    self.card.hidden = NO;
    self.presented = YES;
    [self saveAndDisableAncestorClipping];
    [self deferHostTapsUntilLongPressFails];
    [self refresh];
    [self.card startUpdating];
    if (PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
    PGDebugLog(@"[PG] native child %@ host=%@", NSStringFromClass(host.class), NSStringFromCGRect(host.frame));
}

- (void)refresh {
    if (!self.card) return;
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (!preferences.isEnabled) { [self hide]; return; }
    self.card.cardScale = preferences.cardScale;
    self.card.preferredHeight = preferences.cardHeight;
    self.card.controlsDisplayMode = preferences.controlsDisplayMode;
    self.card.blurAmount = preferences.cardBlur;
    self.card.backgroundOpacity = preferences.cardOpacity;
    self.card.cornerRadius = preferences.cardCornerRadius;
    self.card.cornerStyle = preferences.cornerStyle;
    [self.card refreshAppearance];
    [self layoutCardAnimated:NO];
}

- (void)hide {
    [self.card stopUpdating];
    [self.card removeFromSuperview];
    if (self.host && self.parent && self.host.superview == self.parent && self.originalFrame) self.host.frame = self.originalFrame.CGRectValue;
    [self restoreAncestorClipping];
    if (self.grabber) objc_setAssociatedObject(self.grabber, PGPinnedCardGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.card = nil;
    self.host = nil;
    self.parent = nil;
    self.originalFrame = nil;
    self.grabber = nil;
    self.presented = NO;
    self.holdActive = NO;
    PGDebugLog(@"[PG] native child removed");
}
@end

static void PGPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PerfectGrabberPreferences.sharedPreferences reload];
        PGNativeCardHost *host = [PGNativeCardHost shared];
        if (!PerfectGrabberPreferences.sharedPreferences.isEnabled) [host hide];
        else [host refresh];
    });
}

%group PerfectGrabberHooks
%hook SBGrabberTongue
- (void)_willPresent {
    %orig;
    [PerfectGrabberPreferences.sharedPreferences reload];
    if (!PerfectGrabberPreferences.sharedPreferences.isEnabled) { [[PGNativeCardHost shared] hide]; return; }
    if (!PGIsTopEdgeGrabber(self)) return;
    UIView *host = PGTongueView(self);
    if (host.window) [[PGNativeCardHost shared] showInOriginalHost:host grabber:self];
}
- (void)_willDismiss {
    PGNativeCardHost *state = [PGNativeCardHost shared];
    if (state.presented && (state.holdActive || state.card.isExpanded)) return;
    %orig;
    // 严格原生子视图模式：不搬进独立 UIWindow。系统隐藏/销毁宿主时卡片随之消失。
}
%end
%end

%ctor {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        Class cls = NSClassFromString(@"SBGrabberTongue");
        if (cls && class_getInstanceMethod(cls, @selector(_willPresent)) && class_getInstanceMethod(cls, @selector(_willDismiss)))
            %init(PerfectGrabberHooks, SBGrabberTongue=cls);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [PerfectGrabberPreferences.sharedPreferences reload];
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PGPreferencesChanged,
                (__bridge CFStringRef)PGPreferencesChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        });
    }
}
