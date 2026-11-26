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

#pragma mark - 原生面板内卡片宿主

@interface PGNativeCardHost : NSObject
@property (nonatomic, strong) PGEdgeCardContainer *container;
@property (nonatomic, strong) PGGrabberOverlayView *card;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIWindow *panelWindow;
@property (nonatomic, weak) UIView *panelParent;
@property (nonatomic, weak) UIView *originalHost;
@property (nonatomic, weak) id grabber;
@property (nonatomic, weak) UIView *chevron;
@property (nonatomic, assign) BOOL chevronWasHidden;
@property (nonatomic, assign) BOOL hasChevronState;
@property (nonatomic, assign) CGFloat anchorRatio;
@property (nonatomic, assign) BOOL presented;
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

- (CGFloat)preferredWidth {
    CGFloat width = MAX(300.0, PerfectGrabberPreferences.sharedPreferences.cardWidth);
    return self.card.isExpanded ? width : MIN(440.0, width);
}

- (UIView *)panelCanvasForHost:(UIView *)host {
    // Attach within the active panel's content hierarchy, not to UIWindow itself
    // and never to a separate alert-level overlay window.
    UIWindow *panelWindow = host.window;
    UIView *panelContent = panelWindow.rootViewController.view;
    if (panelContent && panelContent.window == panelWindow) return panelContent;
    return host.superview ?: host;
}

- (CGRect)frameInPanel:(CGFloat)height {
    UIView *canvas = self.panelParent;
    if (!canvas) return CGRectZero;
    CGFloat width = MIN(MAX(260.0, self.preferredWidth), MAX(260.0, CGRectGetWidth(canvas.bounds) - 12.0));
    CGFloat centerX = CGRectGetWidth(canvas.bounds) * ((self.anchorRatio > 0.08 && self.anchorRatio < 0.92) ? self.anchorRatio : 0.5);
    CGFloat left = MAX(6.0, MIN(centerX - width * 0.5, CGRectGetWidth(canvas.bounds) - width - 6.0));
    CGRect anchor = self.originalHost ? [self.originalHost convertRect:self.originalHost.bounds toView:canvas] : CGRectMake(0, 0, CGRectGetWidth(canvas.bounds), 44.0);
    CGFloat top = MAX(2.0, CGRectGetMinY(anchor));
    CGFloat h = MIN(height, MAX(1.0, CGRectGetHeight(canvas.bounds) - top - 4.0));
    return CGRectMake(left, top, width, h);
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window || !self.card || !self.panelParent) return;
    self.window = window;
    if (!self.container) {
        self.container = [[PGEdgeCardContainer alloc] initWithFrame:CGRectZero];
        self.container.backgroundColor = UIColor.clearColor;
        self.container.userInteractionEnabled = YES;
        self.container.card = self.card;
        self.container.clipsToBounds = NO;
    }
    if (self.container.superview != self.panelParent) {
        [self.container removeFromSuperview];
        [self.panelParent addSubview:self.container];
    }
    self.container.frame = self.panelParent.bounds;
    self.container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (self.card.superview != self.container) {
        [self.card removeFromSuperview];
        [self.container addSubview:self.card];
    }
    self.container.hidden = NO;
    self.card.hidden = NO;
    [self.panelParent bringSubviewToFront:self.container];
}

- (void)applyLayoutAnimated:(BOOL)animated {
    if (!self.card || !self.panelParent) return;
    CGRect frame = [self frameInPanel:[self.card heightForWidth:self.preferredWidth]];
    void (^block)(void) = ^{ self.card.frame = frame; [self.card setNeedsLayout]; [self.card layoutIfNeeded]; };
    if (animated) [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:block completion:nil];
    else block();
}

- (void)resizeForHeight:(CGFloat)height {
    if (!self.card || !self.panelParent) return;
    CGRect frame = [self frameInPanel:height];
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:^{ self.card.frame = frame; [self.card setNeedsLayout]; [self.card layoutIfNeeded]; } completion:nil];
}

#pragma mark 生命周期

- (void)presentFromHost:(UIView *)host chevron:(UIView *)chevron grabber:(id)grabber {
    if (!PerfectGrabberPreferences.sharedPreferences.isEnabled) { [self hide]; return; }
    UIWindow *window = host.window;
    if (!window) return;

    self.panelWindow = window;
    self.grabber = grabber;
    self.originalHost = host;

    if (chevron) {
        if (self.chevron && self.chevron != chevron && self.hasChevronState) self.chevron.hidden = self.chevronWasHidden;
        if (self.chevron != chevron) { self.chevronWasHidden = chevron.hidden; self.hasChevronState = YES; }
        self.chevron = chevron;
    }

    if (!self.card) {
        self.card = [[PGGrabberOverlayView alloc] initWithFrame:CGRectZero];
        self.card.compactMode = YES;
        __weak typeof(self) weak = self;
        self.card.onClose = ^{ [weak hide]; };
        self.card.onHeightChange = ^(CGFloat height) { [weak resizeForHeight:height]; };
        self.card.onLongPressStateChange = ^(BOOL active) { [weak longPressChanged:active]; };
    }

    self.panelParent = [self panelCanvasForHost:host];
    if (chevron && self.panelParent) {
        CGRect rect = [chevron convertRect:chevron.bounds toView:self.panelParent];
        CGFloat canvasWidth = MAX(CGRectGetWidth(self.panelParent.bounds), 1.0);
        if (!CGRectIsEmpty(rect)) self.anchorRatio = CGRectGetMidX(rect) / canvasWidth;
    }
    [self attachToWindow:window];
    if (chevron) chevron.hidden = YES;
    self.presented = YES;

    [self refresh];
    [self.card startUpdating];
    if (PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
    PGDebugLog(@"[PG] present in %@", NSStringFromClass(window.class));
}

/// 真正嵌入原生面板：面板收起时卡片随系统离屏，释放面板视图树中的容器；
/// 卡片模型保留，下一次下拉可复用。不会移入游戏上方或额外 UIWindow。
- (void)keepAfterPanelDismiss {
    if (!self.presented || !self.card) return;
    [self.card stopUpdating];
    self.card.hidden = YES;
    [self.container removeFromSuperview];
    self.container = nil;
    self.panelParent = nil;
    if (self.chevron && self.hasChevronState) self.chevron.hidden = self.chevronWasHidden;
    self.presented = NO;
    PGDebugLog(@"[PG] embedded card detached with native panel");
}

- (void)refresh {
    if (!self.card || !self.window) return;
    PerfectGrabberPreferences *p = PerfectGrabberPreferences.sharedPreferences;
    if (!p.isEnabled) { [self hide]; return; }
    self.card.cardScale = p.cardScale;
    self.card.cardHeightScale = p.cardHeightScale;
    self.card.fontWeight = p.fontWeight;
    self.card.longPressControls = p.longPressControls;
    self.card.lyricsLookupEnabled = p.lyricsLookupEnabled;
    self.card.blurAmount = p.cardBlur;
    self.card.backgroundOpacity = p.cardOpacity;
    self.card.cornerRadius = p.cardCornerRadius;
    self.card.cornerStyle = p.cornerStyle;
    [self.card refreshAppearance];
    [self applyLayoutAnimated:NO];
}

- (void)longPressChanged:(BOOL)active {
    self.card.deferNativeGrabberDismissal = active;
}

- (void)hide {
    PGGrabberOverlayView *card = self.card;
    [card stopUpdating];
    [card removeFromSuperview];
    [self.container removeFromSuperview];
    if (self.chevron && self.hasChevronState) self.chevron.hidden = self.chevronWasHidden;
    self.card = nil;
    self.container = nil;
    self.grabber = nil;
    self.chevron = nil;
    self.hasChevronState = NO;
    self.window = nil;
    self.panelWindow = nil;
    self.panelParent = nil;
    self.presented = NO;
    PGDebugLog(@"[PG] hide embedded card");
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
