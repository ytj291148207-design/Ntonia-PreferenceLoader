#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
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
static UIView *PGNamedTongueView(id grabber, NSString *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(grabber), name.UTF8String);
    id value = ivar ? object_getIvar(grabber, ivar) : nil;
    if (![value isKindOfClass:UIView.class]) { @try { value = [grabber valueForKey:name]; } @catch (__unused NSException *e) { value = nil; } }
    return [value isKindOfClass:UIView.class] ? value : nil;
}
static UIView *PGTongueChevron(id grabber) {
    Ivar ivar = class_getInstanceVariable(object_getClass(grabber), "_tongueChevron");
    id value = ivar ? object_getIvar(grabber, ivar) : nil;
    if (![value isKindOfClass:UIView.class]) { @try { value = [grabber valueForKey:@"_tongueChevron"]; } @catch (__unused NSException *e) { value = nil; } }
    return [value isKindOfClass:UIView.class] ? value : nil;
}
static UIView *PGTongueBackdropView(id grabber) {
    for (NSString *name in @[@"_tongueBackdropView", @"_tongueChevronBackgroundView", @"_grabberBackdropView"]) {
        Ivar ivar = class_getInstanceVariable(object_getClass(grabber), name.UTF8String);
        id value = ivar ? object_getIvar(grabber, ivar) : nil;
        if (![value isKindOfClass:UIView.class]) { @try { value = [grabber valueForKey:name]; } @catch (__unused NSException *e) { value = nil; } }
        if ([value isKindOfClass:UIView.class]) return value;
    }
    return nil;
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

/// Higher-level overlay accepts only card hits. Every outside touch goes back
/// to the game so gameplay input is never consumed by the tweak.
@interface PGOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *cardContainer;
@end
@implementation PGOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *container = self.cardContainer;
    for (UIView *view = hit; view; view = view.superview) if (view == container) return hit;
    return nil;
}
@end

/// Keep the overlay window in the same orientation as the game scene. A plain
/// root controller in an auxiliary SpringBoard UIWindow can otherwise stay in
/// portrait while the app underneath rotates to landscape.
@interface PGOverlayRootController : UIViewController
@property (nonatomic, weak) UIWindowScene *targetScene;
@property (nonatomic, weak) UIWindow *targetHostWindow;
@end
@implementation PGOverlayRootController
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientation)pgCurrentInterfaceOrientation {
    // Use the exact scene that owns SpringBoard's original grabber window;
    // using the auxiliary overlay's own scene left the card in portrait.
    UIInterfaceOrientation hostOrientation = self.targetHostWindow.windowScene.interfaceOrientation;
    if (hostOrientation != UIInterfaceOrientationUnknown) return hostOrientation;
    CGSize host = self.targetHostWindow.bounds.size;
    if (host.width > host.height * 1.05) return UIInterfaceOrientationLandscapeLeft;
    if (host.height > host.width * 1.05) return UIInterfaceOrientationPortrait;
    CGSize screen = UIScreen.mainScreen.coordinateSpace.bounds.size;
    if (screen.width > screen.height * 1.05) return UIInterfaceOrientationLandscapeLeft;
    if (screen.height > screen.width * 1.05) return UIInterfaceOrientationPortrait;
    UIDeviceOrientation device = UIDevice.currentDevice.orientation;
    if (device == UIDeviceOrientationLandscapeLeft) return UIInterfaceOrientationLandscapeRight;
    if (device == UIDeviceOrientationLandscapeRight) return UIInterfaceOrientationLandscapeLeft;
    if (device == UIDeviceOrientationPortraitUpsideDown) return UIInterfaceOrientationPortraitUpsideDown;
    return UIInterfaceOrientationPortrait;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    switch ([self pgCurrentInterfaceOrientation]) {
        case UIInterfaceOrientationPortrait: return UIInterfaceOrientationMaskPortrait;
        case UIInterfaceOrientationPortraitUpsideDown: return UIInterfaceOrientationMaskPortraitUpsideDown;
        case UIInterfaceOrientationLandscapeLeft: return UIInterfaceOrientationMaskLandscapeLeft;
        case UIInterfaceOrientationLandscapeRight: return UIInterfaceOrientationMaskLandscapeRight;
        default: return UIInterfaceOrientationMaskAllButUpsideDown;
    }
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return [self pgCurrentInterfaceOrientation];
}
@end

#pragma mark - 卡片宿主与常显覆盖窗口

@interface PGNativeCardHost : NSObject
@property (nonatomic, strong) PGEdgeCardContainer *container;
@property (nonatomic, strong) PGGrabberOverlayView *card;
@property (nonatomic, strong) PGOverlayWindow *overlayWindow;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, weak) UIWindow *panelWindow;
@property (nonatomic, weak) UIView *panelParent;
@property (nonatomic, weak) UIView *originalHost;
@property (nonatomic, weak) id grabber;
@property (nonatomic, weak) UIView *chevron;
@property (nonatomic, assign) BOOL chevronWasHidden;
@property (nonatomic, assign) BOOL hasChevronState;
@property (nonatomic, weak) UIView *nativeBackdrop;
@property (nonatomic, assign) BOOL nativeBackdropWasHidden;
@property (nonatomic, assign) BOOL hasNativeBackdropState;
@property (nonatomic, assign) CGFloat anchorRatio;
@property (nonatomic, assign) CGFloat anchorY;
@property (nonatomic, assign) CGFloat anchorScreenX;
@property (nonatomic, assign) CGFloat anchorScreenY;
@property (nonatomic, assign) BOOL isOverlayActive;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *nativeVisualStates;
@property (nonatomic, assign) BOOL presented;
@property (nonatomic, strong) NSTimer *orientationVisibilityTimer;
@property (nonatomic, assign) BOOL isLandscapeVisible;
+ (instancetype)shared;
- (void)presentFromHost:(UIView *)host chevron:(UIView *)chevron grabber:(id)grabber;
- (void)keepAfterPanelDismiss;
- (void)resizeForHeight:(CGFloat)height;
- (void)longPressChanged:(BOOL)active;
- (void)refresh;
- (void)hide;
- (void)suppressNativeVisualsInView:(UIView *)view root:(BOOL)isRoot;
- (void)restoreNativeVisuals;
- (void)updateOrientationVisibility;
- (BOOL)isLandscapeForWindow:(UIWindow *)window;
- (void)setCardFrame:(CGRect)frame inHost:(UIView *)host;
@end

@implementation PGNativeCardHost

+ (instancetype)shared {
    static PGNativeCardHost *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationDidChange:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)orientationDidChange:(NSNotification *)notification {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PGOverlayRootController *root = (PGOverlayRootController *)self.overlayWindow.rootViewController;
        if (@available(iOS 16.0, *)) [root setNeedsUpdateOfSupportedInterfaceOrientations];
        [root.view setNeedsLayout];
        [root.view layoutIfNeeded];
        self.container.frame = root.view.bounds;
        [self updateOrientationVisibility];
    });
}

#pragma mark 窗口与几何

- (void)updateOrientationVisibility {
    // Use the live physical orientation before the auxiliary scene, which can
    // remain stale during the game-to-home handoff.
    UIWindow *window = self.panelWindow ?: self.overlayWindow;
    if (!self.card || !self.container || !window) return;
    self.isLandscapeVisible = [self isLandscapeForWindow:window];
    if (!self.isLandscapeVisible) {
        self.card.hidden = YES;
        self.container.hidden = YES;
        return;
    }
    self.card.hidden = NO;
    self.container.hidden = NO;
    if (self.overlayWindow) {
        self.overlayWindow.hidden = NO;
        self.overlayWindow.cardContainer = self.container;
    }
    if (self.panelParent) {
        self.container.frame = self.panelParent.bounds;
        [self.panelParent bringSubviewToFront:self.container];
    }
    [self applyLayoutAnimated:NO];
}

- (BOOL)isLandscapeForWindow:(UIWindow *)window {
    // Live screen geometry distinguishes the portrait home screen from a
    // landscape game even when the phone is held sideways or scenes are stale.
    CGSize screen = UIScreen.mainScreen.coordinateSpace.bounds.size;
    if (screen.width > screen.height * 1.05) return YES;
    if (screen.height > screen.width * 1.05) return NO;
    UIInterfaceOrientation hostOrientation = window.windowScene.interfaceOrientation;
    if (hostOrientation != UIInterfaceOrientationUnknown) return UIInterfaceOrientationIsLandscape(hostOrientation);
    CGFloat width = CGRectGetWidth(window.bounds), height = CGRectGetHeight(window.bounds);
    if (width > height * 1.05) return YES;
    if (height > width * 1.05) return NO;
    UIDeviceOrientation device = UIDevice.currentDevice.orientation;
    return UIDeviceOrientationIsLandscape(device);
}

- (BOOL)needsCardCounterRotationInHost:(UIView *)host {
    if (!host) return NO;
    CGSize hostBounds = host.bounds.size;
    BOOL hostCoordinatesArePortrait = hostBounds.height > hostBounds.width * 1.15;
    BOOL displayIsLandscape = [self isLandscapeForWindow:self.panelWindow ?: self.overlayWindow];
    return displayIsLandscape && hostCoordinatesArePortrait;
}

- (void)setCardFrame:(CGRect)frame inHost:(UIView *)host {
    self.card.transform = CGAffineTransformIdentity;
    self.card.frame = frame;
    if ([self needsCardCounterRotationInHost:host]) {
        // The host is still portrait while the display/game is landscape.
        // A clockwise quarter-turn cancels the host's counter-clockwise screen
        // presentation; the resulting visual bounds remain landscape and centered.
        self.card.transform = CGAffineTransformMakeRotation((CGFloat)M_PI_2);
    }
}

- (CGFloat)preferredWidth {
    CGFloat width = MAX(300.0, PerfectGrabberPreferences.sharedPreferences.cardWidth);
    BOOL landscape = [self isLandscapeForWindow:self.overlayWindow ?: self.panelWindow];
    if (landscape) return MIN(width, self.card.isExpanded ? 420.0 : 340.0);
    return self.card.isExpanded ? width : MIN(440.0, width);
}

- (UIWindow *)overlayWindowForScene:(UIWindowScene *)scene hostWindow:(UIWindow *)hostWindow {
    if (!scene) return nil;
    if (self.overlayWindow && self.overlayWindow.windowScene == scene) {
        PGOverlayRootController *existingRoot = (PGOverlayRootController *)self.overlayWindow.rootViewController;
        existingRoot.targetHostWindow = hostWindow;
        existingRoot.targetScene = scene;
        return self.overlayWindow;
    }
    PGOverlayWindow *overlay = [[PGOverlayWindow alloc] initWithWindowScene:scene];
    overlay.windowLevel = UIWindowLevelAlert + 1.0;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.opaque = NO;
    PGOverlayRootController *root = [PGOverlayRootController new];
    root.targetScene = scene;
    root.targetHostWindow = hostWindow;
    root.view.backgroundColor = UIColor.clearColor;
    overlay.rootViewController = root;
    overlay.hidden = NO;
    self.overlayWindow = overlay;
    return overlay;
}

- (UIView *)panelCanvasForHost:(UIView *)host {
    UIWindowScene *scene = host.window.windowScene;
    UIWindow *overlay = [self overlayWindowForScene:scene hostWindow:host.window];
    return overlay.rootViewController.view ?: host.window.rootViewController.view ?: host.superview ?: host;
}

- (id)nullBox:(id)value { return value ?: (id)NSNull.null; }

- (NSDictionary *)snapshotLayer:(CALayer *)layer {
    NSMutableDictionary *state = [@{@"layer":layer,
        @"background": [self nullBox:(__bridge id)layer.backgroundColor],
        @"contents": [self nullBox:layer.contents],
        @"border": [self nullBox:(__bridge id)layer.borderColor],
        @"borderWidth": @(layer.borderWidth),
        @"shadow": @(layer.shadowOpacity)} mutableCopy];
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        state[@"fill"] = [self nullBox:(__bridge id)shape.fillColor];
        state[@"stroke"] = [self nullBox:(__bridge id)shape.strokeColor];
    }
    if ([layer isKindOfClass:CAGradientLayer.class]) {
        CAGradientLayer *gradient = (CAGradientLayer *)layer;
        state[@"gradientColors"] = gradient.colors ?: @[];
        state[@"gradientLocations"] = gradient.locations ?: @[];
        state[@"gradientStart"] = [NSValue valueWithCGPoint:gradient.startPoint];
        state[@"gradientEnd"] = [NSValue valueWithCGPoint:gradient.endPoint];
    }
    NSMutableArray *children = [NSMutableArray array];
    for (CALayer *child in layer.sublayers) [children addObject:[self snapshotLayer:child]];
    state[@"children"] = children;
    return state;
}

- (void)clearLayer:(CALayer *)layer {
    layer.backgroundColor = UIColor.clearColor.CGColor;
    layer.contents = nil;
    layer.borderColor = UIColor.clearColor.CGColor;
    layer.borderWidth = 0.0;
    layer.shadowOpacity = 0.0;
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        shape.fillColor = UIColor.clearColor.CGColor;
        shape.strokeColor = UIColor.clearColor.CGColor;
    }
    if ([layer isKindOfClass:CAGradientLayer.class]) ((CAGradientLayer *)layer).colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.clearColor.CGColor];
    for (CALayer *child in layer.sublayers.copy) [self clearLayer:child];
}

- (void)restoreLayerState:(NSDictionary *)state {
    CALayer *layer = state[@"layer"];
    if (![layer isKindOfClass:CALayer.class]) return;
    id bg = state[@"background"];
    id contents = state[@"contents"];
    id border = state[@"border"];
    layer.backgroundColor = bg == NSNull.null ? nil : (__bridge CGColorRef)bg;
    layer.contents = contents == NSNull.null ? nil : contents;
    layer.borderColor = border == NSNull.null ? nil : (__bridge CGColorRef)border;
    layer.borderWidth = [state[@"borderWidth"] doubleValue];
    layer.shadowOpacity = [state[@"shadow"] floatValue];
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        id fill = state[@"fill"];
        id stroke = state[@"stroke"];
        ((CAShapeLayer *)layer).fillColor = fill == NSNull.null ? nil : (__bridge CGColorRef)fill;
        ((CAShapeLayer *)layer).strokeColor = stroke == NSNull.null ? nil : (__bridge CGColorRef)stroke;
    }
    if ([layer isKindOfClass:CAGradientLayer.class] && state[@"gradientColors"]) {
        CAGradientLayer *gradient = (CAGradientLayer *)layer;
        gradient.colors = state[@"gradientColors"];
        gradient.locations = state[@"gradientLocations"];
        gradient.startPoint = [state[@"gradientStart"] CGPointValue];
        gradient.endPoint = [state[@"gradientEnd"] CGPointValue];
    }
    for (NSDictionary *child in state[@"children"]) [self restoreLayerState:child];
}

- (void)suppressNativeVisualsInView:(UIView *)view root:(BOOL)isRoot {
    if (!view) return;
    if (!self.nativeVisualStates) self.nativeVisualStates = [NSMutableArray array];
    if (view == self.container || view == self.card) return;
    BOOL alreadyCaptured = NO;
    for (NSDictionary *existing in self.nativeVisualStates) if (existing[@"view"] == view) { alreadyCaptured = YES; break; }
    if (alreadyCaptured) {
        // SpringBoard may rebuild/repaint the native capsule during dismissal; re-clear
        // the cached view without replacing its original restoration snapshot.
        view.backgroundColor = UIColor.clearColor;
        if ([view isKindOfClass:UIVisualEffectView.class]) ((UIVisualEffectView *)view).effect = nil;
        [self clearLayer:view.layer];
        if ([view isKindOfClass:UILabel.class]) ((UILabel *)view).textColor = UIColor.clearColor;
        if ([view isKindOfClass:UIImageView.class]) { ((UIImageView *)view).image = nil; ((UIImageView *)view).highlightedImage = nil; }
        if ([view isKindOfClass:UIButton.class]) { [(UIButton *)view setImage:nil forState:UIControlStateNormal]; [(UIButton *)view setTitle:@"" forState:UIControlStateNormal]; }
        if ([view isKindOfClass:UIVisualEffectView.class]) ((UIVisualEffectView *)view).effect = nil;
        for (UIView *child in view.subviews.copy) [self suppressNativeVisualsInView:child root:NO];
        return;
    }
    {
        NSMutableDictionary *state = [@{@"view":view,
            @"background": [self nullBox:view.backgroundColor],
            @"layer": [self snapshotLayer:view.layer]} mutableCopy];
        if ([view isKindOfClass:UILabel.class]) state[@"textColor"] = [self nullBox:((UILabel *)view).textColor];
        if ([view isKindOfClass:UIImageView.class]) {
            state[@"image"] = [self nullBox:((UIImageView *)view).image];
            state[@"highlightedImage"] = [self nullBox:((UIImageView *)view).highlightedImage];
        }
        if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            state[@"buttonImage"] = [self nullBox:[button imageForState:UIControlStateNormal]];
            state[@"buttonTitleColor"] = [self nullBox:[button titleColorForState:UIControlStateNormal]];
            state[@"buttonTitle"] = [self nullBox:[button titleForState:UIControlStateNormal]];
        }
        if ([view isKindOfClass:UIVisualEffectView.class]) state[@"effect"] = [self nullBox:((UIVisualEffectView *)view).effect];
        [self.nativeVisualStates addObject:state];
        view.backgroundColor = UIColor.clearColor;
        if ([view isKindOfClass:UIVisualEffectView.class]) ((UIVisualEffectView *)view).effect = nil;
        [self clearLayer:view.layer];
        if ([view isKindOfClass:UILabel.class]) ((UILabel *)view).textColor = UIColor.clearColor;
        if ([view isKindOfClass:UIImageView.class]) {
            ((UIImageView *)view).image = nil;
            ((UIImageView *)view).highlightedImage = nil;
        }
        if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            [button setImage:nil forState:UIControlStateNormal];
            [button setTitle:@"" forState:UIControlStateNormal];
            [button setTitleColor:UIColor.clearColor forState:UIControlStateNormal];
            button.backgroundColor = UIColor.clearColor;
        }
        if ([view isKindOfClass:UIVisualEffectView.class]) ((UIVisualEffectView *)view).effect = nil;
    }
    for (UIView *child in view.subviews.copy) [self suppressNativeVisualsInView:child root:NO];
}

- (void)restoreNativeVisuals {
    for (NSDictionary *state in self.nativeVisualStates.reverseObjectEnumerator) {
        UIView *view = state[@"view"];
        if (![view isKindOfClass:UIView.class]) continue;
        id bg = state[@"background"];
        view.backgroundColor = bg == NSNull.null ? nil : bg;
        if (state[@"textColor"] && [view isKindOfClass:UILabel.class]) {
            id c = state[@"textColor"]; ((UILabel *)view).textColor = c == NSNull.null ? nil : c;
        }
        if (state[@"image"] && [view isKindOfClass:UIImageView.class]) {
            id image = state[@"image"];
            id highlighted = state[@"highlightedImage"];
            ((UIImageView *)view).image = image == NSNull.null ? nil : image;
            ((UIImageView *)view).highlightedImage = highlighted == NSNull.null ? nil : highlighted;
        }
        if (state[@"buttonTitle"] && [view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            id image = state[@"buttonImage"];
            id title = state[@"buttonTitle"];
            id color = state[@"buttonTitleColor"];
            [button setImage:(image == NSNull.null ? nil : image) forState:UIControlStateNormal];
            [button setTitle:(title == NSNull.null ? nil : title) forState:UIControlStateNormal];
            [button setTitleColor:(color == NSNull.null ? nil : color) forState:UIControlStateNormal];
        }
        if (state[@"effect"] && [view isKindOfClass:UIVisualEffectView.class]) {
            id effect = state[@"effect"]; ((UIVisualEffectView *)view).effect = effect == NSNull.null ? nil : effect;
        }
        [self restoreLayerState:state[@"layer"]];
    }
    [self.nativeVisualStates removeAllObjects];
    self.nativeVisualStates = nil;
}

- (CGRect)frameInPanel:(CGFloat)height {
    UIView *canvas = self.panelParent;
    if (!canvas) return CGRectZero;
    CGFloat canvasWidth = CGRectGetWidth(canvas.bounds);
    CGFloat canvasHeight = CGRectGetHeight(canvas.bounds);
    BOOL landscape = [self isLandscapeForWindow:canvas.window ?: self.panelWindow];
    CGFloat width = MIN(MAX(260.0, self.preferredWidth), MAX(260.0, canvasWidth - 12.0));
    CGPoint anchor = CGPointMake(canvasWidth * 0.5, 0.0);
    UIWindow *targetWindow = canvas.window;
    if (self.panelWindow && targetWindow) {
        CGPoint panelPoint = CGPointMake(self.anchorScreenX, self.anchorScreenY);
        anchor = [self.panelWindow convertPoint:panelPoint toWindow:targetWindow];
    }
    CGFloat xAnchor = (isfinite(anchor.x) && anchor.x >= 0.0) ? anchor.x : canvasWidth * 0.5;
    CGFloat left = landscape ? (canvasWidth - width) * 0.5
                             : MAX(6.0, MIN(xAnchor - width * 0.5, canvasWidth - width - 6.0));
    CGFloat top = MAX(58.0, anchor.y + 10.0);
    CGFloat h = MIN(height, MAX(1.0, canvasHeight - top - 10.0));
    if (landscape) {
        h = MIN(height, MAX(1.0, canvasHeight - 24.0));
        top = (canvasHeight - h) * 0.5;
    }
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
    if (self.overlayWindow && self.panelParent == self.overlayWindow.rootViewController.view) {
        self.overlayWindow.cardContainer = self.container;
        self.window = self.overlayWindow;
    }
    self.container.frame = self.panelParent.bounds;
    self.container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (self.card.superview != self.container) {
        [self.card removeFromSuperview];
        [self.container addSubview:self.card];
    }
    self.container.hidden = NO;
    self.card.hidden = NO;
    if ([self.panelParent.window isKindOfClass:PGOverlayWindow.class]) {
        ((PGOverlayWindow *)self.panelParent.window).cardContainer = self.container;
        self.window = self.panelParent.window;
    }
    [self.panelParent bringSubviewToFront:self.container];
}

- (void)applyLayoutAnimated:(BOOL)animated {
    if (!self.card || !self.panelParent) return;
    CGRect frame = [self frameInPanel:[self.card heightForWidth:self.preferredWidth]];
    void (^block)(void) = ^{ [self setCardFrame:frame inHost:self.panelParent]; [self.card setNeedsLayout]; [self.card layoutIfNeeded]; };
    if (animated) [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:block completion:nil];
    else block();
    if (self.isOverlayActive && self.overlayWindow) {
        CGPoint anchor = [self.panelWindow convertPoint:CGPointMake(self.anchorScreenX, self.anchorScreenY) toWindow:self.overlayWindow];
        CGFloat overlayWidth = CGRectGetWidth(self.overlayWindow.bounds);
        CGFloat overlayHeight = CGRectGetHeight(self.overlayWindow.bounds);
        BOOL landscape = [self isLandscapeForWindow:self.overlayWindow];
        CGFloat width = MIN(frame.size.width, MAX(1.0, overlayWidth - 16.0));
        CGFloat cardHeight = MIN(frame.size.height, MAX(1.0, overlayHeight - 24.0));
        CGFloat x = landscape ? (overlayWidth - width) * 0.5
                              : MAX(8.0, MIN(anchor.x - width * 0.5, overlayWidth - width - 8.0));
        CGFloat y = landscape ? (overlayHeight - cardHeight) * 0.5
                              : MAX(58.0, anchor.y + 10.0);
        CGRect overlayFrame = CGRectMake(x, y, width, cardHeight);
        [self setCardFrame:overlayFrame inHost:self.overlayWindow.rootViewController.view];
        [self.card setNeedsLayout];
        [self.card layoutIfNeeded];
    }
}

- (void)resizeForHeight:(CGFloat)height {
    if (!self.card || !self.panelParent) return;
    CGRect frame = [self frameInPanel:height];
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:^{ [self setCardFrame:frame inHost:self.panelParent]; [self.card setNeedsLayout]; [self.card layoutIfNeeded]; } completion:nil];
    if (self.isOverlayActive && self.overlayWindow) {
        CGPoint anchor = [self.panelWindow convertPoint:CGPointMake(self.anchorScreenX, self.anchorScreenY) toWindow:self.overlayWindow];
        CGFloat overlayWidth = CGRectGetWidth(self.overlayWindow.bounds);
        CGFloat overlayHeight = CGRectGetHeight(self.overlayWindow.bounds);
        BOOL landscape = [self isLandscapeForWindow:self.overlayWindow];
        CGFloat width = MIN(frame.size.width, MAX(1.0, overlayWidth - 16.0));
        CGFloat cardHeight = MIN(height, MAX(1.0, overlayHeight - 24.0));
        CGFloat x = landscape ? (overlayWidth - width) * 0.5
                              : MAX(8.0, MIN(anchor.x - width * 0.5, overlayWidth - width - 8.0));
        CGFloat y = landscape ? (overlayHeight - cardHeight) * 0.5
                              : MAX(anchor.y + 2.0, 8.0);
        [self setCardFrame:CGRectMake(x, y, width, cardHeight) inHost:self.overlayWindow.rootViewController.view];
        [self.card setNeedsLayout];
        [self.card layoutIfNeeded];
    }
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
    UIView *nativeBackdrop = [grabber isKindOfClass:UIView.class] ? (UIView *)grabber : (PGTongueBackdropView(grabber) ?: PGNamedTongueView(grabber, @"_tongueContainer") ?: PGTongueView(grabber) ?: host);
    self.nativeBackdrop = nativeBackdrop;
    if (!self.hasNativeBackdropState) {
        self.nativeBackdropWasHidden = nativeBackdrop.hidden;
        self.hasNativeBackdropState = YES;
    }
    // Hide only the decorative capsule backdrop (not its recognizer-bearing host)
    // so the blue pill cannot show through the transparent card.
    nativeBackdrop.hidden = YES;
    // Keep the gesture-bearing grabber visible and clear its rendered capsule layers.
    if (chevron && self.panelParent) {
        CGRect rect = [chevron convertRect:chevron.bounds toView:self.panelParent];
        CGFloat canvasWidth = MAX(CGRectGetWidth(self.panelParent.bounds), 1.0);
        if (!CGRectIsEmpty(rect)) {
            self.anchorRatio = CGRectGetMidX(rect) / canvasWidth;
            self.anchorY = CGRectGetMinY(rect);
            CGRect screenRect = [chevron convertRect:chevron.bounds toView:self.panelWindow];
            self.anchorScreenX = CGRectGetMidX(screenRect);
            self.anchorScreenY = CGRectGetMaxY(screenRect);
        }
    }
    [self attachToWindow:window];
    // Parent tongue tap must wait for the no-op shield and hold recognizer;
    // do not interfere with Control Center's pan-to-dismiss recognizers.
    for(UIView *view=host;view&&view!=window;view=view.superview){
        for(UIGestureRecognizer *r in [view.gestureRecognizers copy]){
            if(r==self.card.interactionShieldRecognizer||r==self.card.cardLongPressRecognizer||![r isKindOfClass:UITapGestureRecognizer.class])continue;
            @try{[r requireGestureRecognizerToFail:self.card.interactionShieldRecognizer];[r requireGestureRecognizerToFail:self.card.cardLongPressRecognizer];}@catch(__unused NSException *e){}
        }
    }
    if (chevron) chevron.hidden = YES;
    self.presented = YES;
    [self.orientationVisibilityTimer invalidate];
    self.orientationVisibilityTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateOrientationVisibility) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.orientationVisibilityTimer forMode:NSRunLoopCommonModes];
    [self updateOrientationVisibility];

    [self refresh];
    [self.card startUpdating];
    [self suppressNativeVisualsInView:nativeBackdrop root:YES];
    if (self.card.isExpanded) [self keepAfterPanelDismiss];
    if (PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
    PGDebugLog(@"[PG] present in %@", NSStringFromClass(window.class));
}

/// 面板的 dismiss 通知不应把已展开的卡片复位或卸载；卡片继续留在同一面板窗口视图树。
/// 这也是“常显/不会自己缩回”的关键：仅设置控件和用户手动箭头改变展开态。
- (void)keepAfterPanelDismiss {
    if (!self.card || !self.container || !self.overlayWindow || self.isOverlayActive) return;
    [self updateOrientationVisibility];
    if (!self.isLandscapeVisible) {
        // Keep the card model alive so it can reappear in the next landscape
        // session, but never migrate its auxiliary window onto the portrait home screen.
        self.container.hidden = YES;
        self.card.hidden = YES;
        return;
    }
    if (self.nativeBackdrop) [self suppressNativeVisualsInView:self.nativeBackdrop root:YES];
    self.isOverlayActive = YES;
    self.panelParent = self.overlayWindow.rootViewController.view;
    self.window = self.overlayWindow;
    self.card.hidden = NO;
    self.container.hidden = NO;
    self.container.frame = self.panelParent.bounds;
    self.container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (self.container.superview != self.panelParent) {
        [self.container removeFromSuperview];
        [self.panelParent addSubview:self.container];
    }
    self.overlayWindow.cardContainer = self.container;
    [self.panelParent bringSubviewToFront:self.container];
    [self applyLayoutAnimated:NO];
    PGDebugLog(@"[PG] card transferred to persistent game overlay");
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
    if (active && self.card.isExpanded) [self keepAfterPanelDismiss];
}

- (void)hide {
    [self.orientationVisibilityTimer invalidate];self.orientationVisibilityTimer=nil;self.isLandscapeVisible=NO;
    if (self.overlayWindow) {
        self.overlayWindow.cardContainer = nil;
        self.overlayWindow.hidden = YES;
        self.overlayWindow = nil;
    }
    [self restoreNativeVisuals];
    if (self.nativeBackdrop && self.hasNativeBackdropState) self.nativeBackdrop.hidden = self.nativeBackdropWasHidden;
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
