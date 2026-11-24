#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PGGrabberOverlayView.h"
#import "PGNowPlaying.h"
#import "PerfectGrabberPreferences.h"

extern "C" void PGDebugLog(NSString *format, ...);
@interface PGEdgeCardWindow : NSObject
+ (instancetype)sharedWindow;
- (void)showForHostView:(UIView *)host;
- (void)hide;
- (void)refresh;
@end
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
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:PGLogPath];
        [h seekToEndOfFile]; [h writeData:[[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
    } @catch (__unused NSException *e) { }
    [PGLogLock unlock];
}

static UIView *PGTongueView(id grabber) {
    for (NSString *name in @[@"_tongueContainer", @"_tongueBackdropView", @"_containingView"]) {
        Ivar iv = class_getInstanceVariable(object_getClass(grabber), name.UTF8String);
        id value = iv ? object_getIvar(grabber, iv) : nil;
        if (![value isKindOfClass:UIView.class]) {
            @try { value = [grabber valueForKey:name]; } @catch (__unused NSException *e) { value = nil; }
        }
        if ([value isKindOfClass:UIView.class]) return value;
    }
    return [grabber isKindOfClass:UIView.class] ? grabber : nil;
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
        } @catch (__unused NSException *e) { }
    }
    UIView *view = PGTongueView(grabber);
    UIWindow *window = view.window;
    if (view && window) {
        CGRect rect = [view convertRect:view.bounds toView:window];
        return CGRectGetMinY(rect) < CGRectGetHeight(window.bounds) - CGRectGetMaxY(rect);
    }
    return YES;
}

static void PGPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PerfectGrabberPreferences.sharedPreferences reload];
        if (!PerfectGrabberPreferences.sharedPreferences.isEnabled) {
            [[PGEdgeCardWindow sharedWindow] hide];
            return;
        }
        [[PGEdgeCardWindow sharedWindow] refresh];
    });
}

%group PerfectGrabberHooks
%hook SBGrabberTongue
- (void)_willPresent {
    %orig;
    [PerfectGrabberPreferences.sharedPreferences reload];
    if (!PerfectGrabberPreferences.sharedPreferences.isEnabled || !PGIsTopEdgeGrabber(self)) {
        [[PGEdgeCardWindow sharedWindow] hide];
        return;
    }
    UIView *host = PGTongueView(self);
    if (!host.window) return;
    UIView *chevron = nil;
    Ivar iv = class_getInstanceVariable(object_getClass(self), "_tongueChevron");
    id candidate = iv ? object_getIvar(self, iv) : nil;
    if ([candidate isKindOfClass:UIView.class]) chevron = candidate;
    if (chevron) chevron.hidden = YES;
    [[PGEdgeCardWindow sharedWindow] showForHostView:host];
}

// Deliberately do not hide the independent card here. It remains docked after
// SpringBoard collapses Control Center; only the card's own close button hides it.
- (void)_willDismiss {
    %orig;
}
%end
%end

%ctor {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        Class cls = NSClassFromString(@"SBGrabberTongue");
        if (cls && class_getInstanceMethod(cls, @selector(_willPresent)) && class_getInstanceMethod(cls, @selector(_willDismiss))) {
            %init(PerfectGrabberHooks, SBGrabberTongue = cls);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [PerfectGrabberPreferences.sharedPreferences reload];
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                            PGPreferencesChanged,
                                            (__bridge CFStringRef)PGPreferencesChangedNotification,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        });
    }
}

#pragma mark - Non-key edge-card window host

@interface PGEdgePassThroughWindow : UIWindow
@property (nonatomic, weak) UIView *card;
@end
@interface PGEdgeCardRootController : UIViewController
@property (nonatomic, copy) void (^onLayout)(void);
@property (nonatomic, assign) CGSize lastSize;
@end
@implementation PGEdgeCardRootController
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAllButUpsideDown; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    if (CGSizeEqualToSize(size, self.lastSize)) return;
    self.lastSize = size;
    if (self.onLayout) self.onLayout();
}
@end

@implementation PGEdgePassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.card || self.card.hidden || !self.card.userInteractionEnabled) return nil;
    CGPoint cardPoint = [self.card convertPoint:point fromView:self];
    if (![self.card pointInside:cardPoint withEvent:event]) return nil;
    return [self.card hitTest:cardPoint withEvent:event];
}
@end

@interface PGEdgeCardWindow ()
@property (nonatomic, strong) PGEdgePassThroughWindow *window;
@property (nonatomic, strong) PGGrabberOverlayView *card;
@end
@implementation PGEdgeCardWindow
+ (instancetype)sharedWindow {
    static PGEdgeCardWindow *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}
- (UIWindowScene *)hostScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState != UISceneActivationStateUnattached) return (UIWindowScene *)scene;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) if (window.windowScene) return window.windowScene;
#pragma clang diagnostic pop
    return nil;
}
- (void)showForHostView:(UIView *)host {
    if (!host.window) return;
    if (!self.window) {
        UIWindowScene *scene = host.window.windowScene ?: [self hostScene];
        if (!scene) return;
        self.window = [[PGEdgePassThroughWindow alloc] initWithWindowScene:scene];
        self.window.windowLevel = UIWindowLevelAlert + 1000000.0;
        self.window.backgroundColor = UIColor.clearColor;
        self.window.userInteractionEnabled = YES;
        PGEdgeCardRootController *root = [PGEdgeCardRootController new];
        self.window.rootViewController = root;
        self.window.rootViewController.view.backgroundColor = UIColor.clearColor;
        __weak typeof(self) weakSelf = self;
        root.onLayout = ^{ [weakSelf refresh]; };
        self.card = [[PGGrabberOverlayView alloc] initWithFrame:CGRectZero];
        self.card.translatesAutoresizingMaskIntoConstraints = YES;
        self.card.onClose = ^{ [weakSelf hide]; };
        self.window.card = self.card;
        [self.window.rootViewController.view addSubview:self.card];
    }
    self.window.hidden = NO;
    [self.card startUpdating];
    [self refresh];
}
- (void)refresh {
    if (!self.window || self.window.hidden || !self.card) return;
    PerfectGrabberPreferences *p = PerfectGrabberPreferences.sharedPreferences;
    if (!p.isEnabled) { [self hide]; return; }
    CGRect bounds = self.window.bounds;
    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGFloat availableWidth = MAX(0.0, bounds.size.width - 24.0);
    CGFloat width = MIN(availableWidth, MAX(220.0, p.cardWidth));
    CGFloat top = MAX(safe.top + 6.0, 18.0);
    self.card.cardScale = p.cardScale;
    self.card.blurAmount = p.cardBlur;
    self.card.backgroundOpacity = p.cardOpacity;
    self.card.cornerRadius = p.cardCornerRadius;
    CGFloat height = [self.card heightForWidth:width];
    self.card.frame = CGRectMake((bounds.size.width - width) / 2.0, top, width, height);
    __weak typeof(self) weakSelf = self;
    self.card.onHeightChange = ^(CGFloat updatedHeight) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.window || strongSelf.window.hidden) return;
        CGRect frame = strongSelf.card.frame;
        frame.size.height = updatedHeight;
        strongSelf.card.frame = frame;
        [strongSelf.card setNeedsLayout];
    };
    [self.card setNeedsLayout];
}
- (void)hide {
    [self.card stopUpdating];
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    self.card = nil;
}
@end
