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
        if (![value isKindOfClass:UIView.class]) { @try { value = [grabber valueForKey:name]; } @catch (__unused NSException *e) { value = nil; } }
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
        @try { id value=[grabber valueForKey:key]; if([value respondsToSelector:@selector(integerValue)]){NSInteger edge=[value integerValue];if(edge==UIRectEdgeTop)return YES;if(edge==UIRectEdgeBottom)return NO;} } @catch (__unused NSException *e) { }
    }
    UIView *view=PGTongueView(grabber); UIWindow *window=view.window;
    if(view&&window){CGRect r=[view convertRect:view.bounds toView:window];return CGRectGetMinY(r)<CGRectGetHeight(window.bounds)-CGRectGetMaxY(r);} return YES;
}

#pragma mark - 卡片容器：只让卡片本身吃触摸，其余区域全部穿透

@interface PGEdgeCardContainer : UIView
@property (nonatomic, weak) PGGrabberOverlayView *card;
@end

@implementation PGEdgeCardContainer
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    PGGrabberOverlayView *card = self.card;
    if (self.hidden || !card || card.hidden || !card.userInteractionEnabled) return nil;
    CGPoint local = [card convertPoint:point fromView:self];
    if (![card pointInside:local withEvent:event]) return nil;
    UIView *hit = [card hitTest:local withEvent:event];
    return hit ?: card;
}
@end

/// 专用悬浮窗：层级高于 App 和原生面板，卡片关掉时整个窗口隐藏。
/// hitTest 只放行 container 及其子视图，其余点一律返回 nil，让事件穿到下面的窗口。
@interface PGOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *cardContainer;
@end

@implementation PGOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;
    UIView *container = self.cardContainer;
    for (UIView *view = hit; view; view = view.superview) {
        if (view == container) return hit;
    }
    return nil;
}
@end

#pragma mark - 宿主：卡片挂在窗口上，不再寄生在 SBGrabberTongue 的容器里
//
// 旧实现把卡片塞进 _tongueContainer，再改写它的 frame 去凑卡片大小。那条路必然出三个问题：
//   1. SpringBoard 每次布局都会把 tongue 的 frame 重置回原生尺寸 —— 卡片被压回 44pt（"自己缩回"）；
//   2. tongue 自己带 clipsToBounds，展开多出来的高度直接被裁掉（"长按没反应"）；
//   3. 胶囊端头和箭头没被完全盖住，圆角外侧露出一块（截图右侧那个 ∧）。
// 现在卡片是窗口层上的独立视图，位置和尺寸只由自己算，原生面板动不了它。

@interface PGNativeCardHost : NSObject
@property (nonatomic, strong) PGEdgeCardContainer *container;
@property (nonatomic, strong) PGGrabberOverlayView *card;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIWindow *panelWindow;
@property (nonatomic, weak) id grabber;
@property (nonatomic, weak) UIView *chevron;
@property (nonatomic, assign) BOOL chevronWasHidden;
@property (nonatomic, assign) BOOL hasChevronState;
@property (nonatomic, assign) CGFloat anchorRatio;
@property (nonatomic, assign) BOOL presented;
@property (nonatomic, strong) UIWindow *overlayWindow;
+ (instancetype)shared;
- (void)presentFromHost:(UIView *)host chevron:(UIView *)chevron grabber:(id)grabber;
- (void)keepAfterPanelDismiss;
- (void)resizeForHeight:(CGFloat)height;
- (void)longPressChanged:(BOOL)active;
- (void)refresh;
- (void)hide;
@end

@implementation PGNativeCardHost

+ (instancetype)shared {
    static PGNativeCardHost *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}

#pragma mark 窗口与几何

- (UIWindow *)mainWindowInScene:(UIWindowScene *)scene {
    if (!scene) return nil;
    UIWindow *fallback = nil;
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.windowLevel > UIWindowLevelNormal) continue;
        NSString *name = NSStringFromClass(window.class);
        if ([name containsString:@"MainDisplay"] || [name containsString:@"SBMainDisplay"]) return window;
        if (!fallback) fallback = window;
    }
    return fallback;
}

- (CGFloat)preferredWidth {
    CGFloat width = MAX(300.0, PerfectGrabberPreferences.sharedPreferences.cardWidth);
    return self.card.isExpanded ? width : MIN(300.0, width);
}

- (CGRect)frameForWindow:(UIWindow *)window height:(CGFloat)height {
    if (!window) return CGRectZero;
    CGRect bounds = window.bounds;
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat inset = MAX(5.0, MAX(safe.left, safe.right)) + 2.0;
    CGFloat available = MAX(240.0, CGRectGetWidth(bounds) - inset * 2.0);
    CGFloat width = MIN(available, self.preferredWidth);
    CGFloat ratio = (self.anchorRatio > 0.08 && self.anchorRatio < 0.92) ? self.anchorRatio : 0.5;
    CGFloat center = CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * ratio;
    CGFloat left = center - width * 0.5;
    left = MAX(CGRectGetMinX(bounds) + inset, MIN(left, CGRectGetMaxX(bounds) - inset - width));
    // 自建悬浮窗的 safeAreaInsets 偶尔是 0，退化成状态栏高度，避免卡片贴到屏幕最上沿
    CGFloat topInset = safe.top > 1.0 ? safe.top : 22.0;
    CGFloat top = CGRectGetMinY(bounds) + topInset + 4.0;
    return CGRectMake(left, top, width, height);
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window || !self.card) return;
    UIWindow *previous = self.window;
    self.window = window;
    if (!self.container) {
        self.container = [[PGEdgeCardContainer alloc] initWithFrame:window.bounds];
        self.container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.container.backgroundColor = UIColor.clearColor;
        self.container.userInteractionEnabled = YES;
        self.container.card = self.card;
    }
    if (self.container.superview != window) {
        [self.container removeFromSuperview];
        [window addSubview:self.container];
    }
    if (self.card.superview != self.container) {
        [self.card removeFromSuperview];
        [self.container addSubview:self.card];
    }
    self.container.frame = window.bounds;
    self.container.hidden = NO;
    self.card.hidden = NO;
    [window bringSubviewToFront:self.container];
    if ([window isKindOfClass:PGOverlayWindow.class]) {
        ((PGOverlayWindow *)window).cardContainer = self.container;
    }
    if (previous && previous != window && [previous isKindOfClass:PGOverlayWindow.class]) {
        ((PGOverlayWindow *)previous).cardContainer = nil;
        previous.hidden = YES;
    }
}

- (void)applyLayoutAnimated:(BOOL)animated {
    if (!self.card || !self.window) return;
    CGRect frame = [self frameForWindow:self.window height:[self.card heightForWidth:self.preferredWidth]];
    void (^block)(void) = ^{
        self.card.frame = frame;
        [self.card setNeedsLayout];
        [self.card layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.26 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:block completion:nil];
    } else {
        block();
    }
}

- (void)resizeForHeight:(CGFloat)height {
    if (!self.card || !self.window) return;
    CGRect frame = [self frameForWindow:self.window height:MAX(1.0, height)];
    [UIView animateWithDuration:0.26 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self.card.frame = frame;
        [self.card setNeedsLayout];
        [self.card layoutIfNeeded];
    } completion:nil];
}

#pragma mark 生命周期

- (void)presentFromHost:(UIView *)host chevron:(UIView *)chevron grabber:(id)grabber {
    if (!PerfectGrabberPreferences.sharedPreferences.isEnabled) { [self hide]; return; }
    UIWindow *window = host.window;
    if (!window) return;

    self.panelWindow = window;
    self.grabber = grabber;

    if (chevron) {
        if (self.chevron && self.chevron != chevron && self.hasChevronState) self.chevron.hidden = self.chevronWasHidden;
        if (self.chevron != chevron) { self.chevronWasHidden = chevron.hidden; self.hasChevronState = YES; }
        self.chevron = chevron;
        CGRect rect = [chevron convertRect:chevron.bounds toView:window];
        CGFloat windowWidth = MAX(CGRectGetWidth(window.bounds), 1.0);
        if (!CGRectIsEmpty(rect)) self.anchorRatio = CGRectGetMidX(rect) / windowWidth;
    }

    if (!self.card) {
        self.card = [[PGGrabberOverlayView alloc] initWithFrame:CGRectZero];
        self.card.compactMode = YES;
        __weak typeof(self) weak = self;
        self.card.onClose = ^{ [weak hide]; };
        self.card.onHeightChange = ^(CGFloat height) { [weak resizeForHeight:height]; };
        self.card.onLongPressStateChange = ^(BOOL active) { [weak longPressChanged:active]; };
    }

    [self attachToWindow:window];
    if (chevron) chevron.hidden = YES;
    self.presented = YES;

    [self refresh];
    [self.card startUpdating];
    if (PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
    PGDebugLog(@"[PG] present in %@", NSStringFromClass(window.class));
}

/// 悬浮窗：只建一次，绑定到当前 windowScene。
- (UIWindow *)overlayWindowForScene:(UIWindowScene *)scene {
    if (!scene) return nil;
    if (self.overlayWindow && self.overlayWindow.windowScene == scene) return self.overlayWindow;
    PGOverlayWindow *window = [[PGOverlayWindow alloc] initWithWindowScene:scene];
    if (!window) return nil;
    window.windowLevel = UIWindowLevelAlert + 1.0;
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = controller;
    window.hidden = NO;
    self.overlayWindow = window;
    PGDebugLog(@"[PG] overlay window ready");
    return window;
}

/// 原生下拉面板收起：把卡片搬到自己的悬浮窗，不销毁、不改展开状态。
/// 面板自己的窗口在收起后可能被隐藏或重建，所以不能把卡片留在里面。
- (void)keepAfterPanelDismiss {
    if (!self.presented || !self.card) return;
    UIWindowScene *scene = self.window.windowScene ?: self.panelWindow.windowScene;
    UIWindow *target = [self overlayWindowForScene:scene] ?: [self mainWindowInScene:scene];
    if (!target || target == self.window) return;
    [self attachToWindow:target];
    [self applyLayoutAnimated:NO];
    if (self.chevron && self.hasChevronState) self.chevron.hidden = self.chevronWasHidden;
    PGDebugLog(@"[PG] docked in %@", NSStringFromClass(target.class));
}

- (void)refresh {
    if (!self.card || !self.window) return;
    PerfectGrabberPreferences *p = PerfectGrabberPreferences.sharedPreferences;
    if (!p.isEnabled) { [self hide]; return; }
    self.card.cardScale = p.cardScale;
    self.card.blurAmount = p.cardBlur;
    self.card.backgroundOpacity = p.cardOpacity;
    self.card.cornerRadius = p.cardCornerRadius;
    self.card.cornerStyle = p.cornerStyle;
    [self.card refreshAppearance];
    [self applyLayoutAnimated:NO];
}

- (void)longPressChanged:(BOOL)active {
    // 只作为"按住中"的标记：卡片已经不在面板的视图树里，不需要再跟原生手势抢。
    self.card.deferNativeGrabberDismissal = active;
    if (self.grabber) objc_setAssociatedObject(self.grabber, PGPinnedCardGuardKey,
                                               active ? @(-1.0) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)hide {
    PGGrabberOverlayView *card = self.card;
    [card stopUpdating];
    [card removeFromSuperview];
    [self.container removeFromSuperview];
    if (self.grabber) objc_setAssociatedObject(self.grabber, PGPinnedCardGuardKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.chevron && self.hasChevronState) self.chevron.hidden = self.chevronWasHidden;
    if ([self.window isKindOfClass:PGOverlayWindow.class]) {
        ((PGOverlayWindow *)self.window).cardContainer = nil;
        self.window.hidden = YES;
    }
    self.overlayWindow.hidden = YES;
    self.overlayWindow = nil;
    self.card = nil;
    self.container = nil;
    self.grabber = nil;
    self.chevron = nil;
    self.hasChevronState = NO;
    self.window = nil;
    self.panelWindow = nil;
    self.presented = NO;
    PGDebugLog(@"[PG] hide");
}

@end

static void PGPreferencesChanged(CFNotificationCenterRef center,void *observer,CFStringRef name,const void*object,CFDictionaryRef info){dispatch_async(dispatch_get_main_queue(),^{[PerfectGrabberPreferences.sharedPreferences reload];if(!PerfectGrabberPreferences.sharedPreferences.isEnabled)[[PGNativeCardHost shared]hide];else [[PGNativeCardHost shared]refresh];});}

%group PerfectGrabberHooks
%hook SBGrabberTongue
- (void)_willPresent{
    %orig;
    [PerfectGrabberPreferences.sharedPreferences reload];
    if(!PerfectGrabberPreferences.sharedPreferences.isEnabled){[[PGNativeCardHost shared]hide];return;}
    if(!PGIsTopEdgeGrabber(self))return;
    UIView*host=PGTongueView(self);if(host.window)[[PGNativeCardHost shared]presentFromHost:host chevron:PGTongueChevron(self) grabber:self];
}
- (void)_willDismiss{
    %orig;
    // 面板收起只做一次换窗搬运：卡片保持展开状态，不销毁。
    [[PGNativeCardHost shared] keepAfterPanelDismiss];
}
%end
%end

%ctor{
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        Class cls = NSClassFromString(@"SBGrabberTongue");
        if (cls && class_getInstanceMethod(cls, @selector(_willPresent)) && class_getInstanceMethod(cls, @selector(_willDismiss))) {
            %init(PerfectGrabberHooks, SBGrabberTongue = cls);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [PerfectGrabberPreferences.sharedPreferences reload];
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PGPreferencesChanged,
                                           (__bridge CFStringRef)PGPreferencesChangedNotification, NULL,
                                           CFNotificationSuspensionBehaviorDeliverImmediately);
        });
    }
}
