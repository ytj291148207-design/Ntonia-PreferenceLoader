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
static IMP PGOriginalTongueWillDismissIMP = NULL;

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

#pragma mark - One card: child of original pill, reparented on panel collapse
@interface PGEdgeCardContainer : UIView
@property(nonatomic,weak) PGGrabberOverlayView *card;
@end
@implementation PGEdgeCardContainer
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    PGGrabberOverlayView *card=self.card;
    if(self.hidden||!card||card.hidden||!card.userInteractionEnabled)return nil;
    CGPoint local=[card convertPoint:point fromView:self];
    return [card pointInside:local withEvent:event]?[card hitTest:local withEvent:event]:nil;
}
@end

@interface PGNativeCardHost : NSObject
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,weak) UIWindow *sourceWindow;
@property(nonatomic,weak) UIView *host;
@property(nonatomic,weak) UIView *parent;
@property(nonatomic,weak) UIView *chevron;
@property(nonatomic,weak) id grabber;
@property(nonatomic,strong) NSValue *originalFrame;
@property(nonatomic,strong) NSValue *anchorRect;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *clipState;
@property(nonatomic,strong) PGEdgeCardContainer *container;
@property(nonatomic,strong) PGGrabberOverlayView *card;
@property(nonatomic,assign) BOOL chevronWasHidden;
@property(nonatomic,assign) BOOL hasChevronState;
@property(nonatomic,assign) BOOL held;
@property(nonatomic,assign) BOOL holdActive;
@property(nonatomic,assign) CFTimeInterval releaseGrace;
@property(nonatomic,assign) BOOL docked;
+ (instancetype)shared;
- (void)show:(UIView *)host chevron:(UIView *)chevron grabber:(id)grabber;
- (void)refresh;
- (void)resizeForHeight:(CGFloat)height;
- (void)longPressChanged:(BOOL)active;
- (void)dockSameCardAfterDismiss;
- (void)hide;
@end

@implementation PGNativeCardHost
+ (instancetype)shared { static PGNativeCardHost *instance; static dispatch_once_t once; dispatch_once(&once,^{instance=[self new];}); return instance; }

- (UIWindow *)persistentWindowForHost:(UIView *)host {
    UIWindow *source=host.window; UIWindowScene *scene=source.windowScene;
    if(scene){
        for(UIWindow *window in scene.windows){NSString *name=NSStringFromClass(window.class);if(!window.hidden&&([name containsString:@"MainDisplay"]||[name containsString:@"SBMainDisplay"]))return window;}
        for(UIWindow *window in scene.windows)if(!window.hidden&&window.windowLevel<=UIWindowLevelNormal&&window!=source)return window;
    }
    return source;
}
- (void)saveAndDisableClipping {
    if(self.clipState)return; self.clipState=[NSMutableArray array];
    for(UIView *view=self.host.superview;view&&view!=self.sourceWindow;view=view.superview){[self.clipState addObject:@{@"view":view,@"clips":@(view.clipsToBounds)}];view.clipsToBounds=NO;}
}
- (void)restoreClipping {
    for(NSDictionary *entry in self.clipState){UIView *view=entry[@"view"];if(view)view.clipsToBounds=[entry[@"clips"]boolValue];}self.clipState=nil;
}
- (void)restoreClips { [self restoreClipping]; }
- (CGFloat)preferredWidth {
    CGFloat width=MAX(300.0,PerfectGrabberPreferences.sharedPreferences.cardWidth);
    return self.card.isExpanded?width:MIN(300.0,width);
}
- (CGRect)frameForWindow:(UIWindow *)window height:(CGFloat)height {
    if(!window)return CGRectZero;CGRect bounds=window.bounds;UIEdgeInsets safe=window.safeAreaInsets;
    CGFloat inset=MAX(5.0,MAX(safe.left,safe.right));
    CGFloat width=MIN(MAX(240.0,CGRectGetWidth(bounds)-2.0*inset),self.preferredWidth);
    CGRect anchor=self.anchorRect.CGRectValue;UIView *chevron=self.chevron;
    if(chevron.window==self.sourceWindow&&self.sourceWindow){CGRect r=[chevron convertRect:chevron.bounds toView:self.sourceWindow];anchor=[self.sourceWindow convertRect:r toView:window];self.anchorRect=[NSValue valueWithCGRect:anchor];}
    else if(chevron.window==window){anchor=[chevron convertRect:chevron.bounds toView:window];self.anchorRect=[NSValue valueWithCGRect:anchor];}
    CGFloat center=CGRectIsEmpty(anchor)?CGRectGetMidX(bounds):CGRectGetMidX(anchor);
        CGFloat left=MAX(CGRectGetMinX(bounds)+inset,MIN(center-width*0.5,CGRectGetMaxX(bounds)-inset-width));
    CGFloat top=CGRectGetMinY(bounds)+safe.top+4.0;
    return CGRectMake(left,top,width,height);
}
- (void)deferAncestorTaps {
    UIGestureRecognizer *hold=nil;for(UIGestureRecognizer *g in self.card.gestureRecognizers)if([g isKindOfClass:UILongPressGestureRecognizer.class]){hold=g;break;}if(!hold)return;
    for(UIView *view=self.host;view;view=view.superview){
        for(UIGestureRecognizer *recognizer in view.gestureRecognizers)if(recognizer!=hold&&[recognizer isKindOfClass:UITapGestureRecognizer.class])[recognizer requireGestureRecognizerToFail:hold];
        if(view==self.sourceWindow)break;
    }
}
- (void)show:(UIView *)host chevron:(UIView *)chevron grabber:(id)grabber {
    UIWindow *source=host.window;if(!source||!host.superview)return;
    BOOL newHost=(self.host!=host||!self.card);
    if(self.card&&self.docked){[self.card removeFromSuperview];[self.container removeFromSuperview];self.container=nil;self.docked=NO;}
    self.sourceWindow=source;self.window=source;self.host=host;self.parent=host.superview;self.grabber=grabber;
    if(newHost||!self.originalFrame)self.originalFrame=[NSValue valueWithCGRect:host.frame];
    if(chevron&&self.chevron!=chevron){if(self.hasChevronState)self.chevron.hidden=self.chevronWasHidden;self.chevron=chevron;self.chevronWasHidden=chevron.hidden;self.hasChevronState=YES;}
    else if(!self.chevron&&chevron){self.chevron=chevron;self.chevronWasHidden=chevron.hidden;self.hasChevronState=YES;}
    UIView *anchor=chevron?:host;self.anchorRect=[NSValue valueWithCGRect:[anchor convertRect:anchor.bounds toView:source]];
    if(!self.card){
        self.card=[[PGGrabberOverlayView alloc]initWithFrame:host.bounds];self.card.compactMode=YES;
        __weak typeof(self) weak=self;self.card.onClose=^{[weak hide];};
        self.card.onHeightChange=^(CGFloat height){[weak resizeForHeight:height];};
        self.card.onLongPressStateChange=^(BOOL active){[weak longPressChanged:active];};
    }
    if(self.card.superview!=host){[self.card removeFromSuperview];[host addSubview:self.card];self.docked=NO;}
    self.card.deferNativeGrabberDismissal=YES;self.card.hidden=NO;if(self.chevron)self.chevron.hidden=YES;
    [self saveAndDisableClipping];[self deferAncestorTaps];[self refresh];[self.card startUpdating];
    if(PerfectGrabberPreferences.sharedPreferences.vibrationFeedback)AudioServicesPlaySystemSound(1519);
}
- (void)refresh {
    if(!self.card||!self.window)return;PerfectGrabberPreferences *p=PerfectGrabberPreferences.sharedPreferences;
    if(!p.isEnabled){[self hide];return;}
    self.card.cardScale=p.cardScale;self.card.blurAmount=p.cardBlur;self.card.backgroundOpacity=p.cardOpacity;self.card.cornerRadius=p.cardCornerRadius;
    [self.card refreshAppearance];
    CGRect frame=[self frameForWindow:self.window height:[self.card heightForWidth:self.preferredWidth]];
    if(self.card.superview==self.host&&self.host.superview==self.parent){self.host.frame=[self.window convertRect:frame toView:self.parent];self.card.frame=self.host.bounds;}
    else if(self.card.superview==self.container){self.container.frame=self.window.bounds;self.card.frame=frame;}
    [self.card setNeedsLayout];
}
- (void)resizeForHeight:(CGFloat)height {
    if(self.card.superview==self.container){CGRect frame=[self frameForWindow:self.window height:height];[UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:^{self.card.frame=frame;[self.card layoutIfNeeded];} completion:nil];return;}
    if(!self.host||!self.parent||!self.window||self.card.superview!=self.host)return;
    CGRect frame=[self.window convertRect:[self frameForWindow:self.window height:height] toView:self.parent];
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:^{self.host.frame=frame;self.card.frame=self.host.bounds;[self.card layoutIfNeeded];} completion:nil];
}
- (void)longPressChanged:(BOOL)active {
    self.holdActive=active;self.releaseGrace=0.0;self.card.deferNativeGrabberDismissal=YES;
    if(self.grabber)objc_setAssociatedObject(self.grabber,PGPinnedCardGuardKey,active?@(-1.0):nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)dockSameCardAfterDismiss {
    if(!self.card||!self.sourceWindow||self.docked)return;
    UIWindow *targetWindow=[self persistentWindowForHost:self.host]?:self.sourceWindow;
    CGRect target=[self frameForWindow:targetWindow height:[self.card heightForWidth:self.preferredWidth]];
    [self.card removeFromSuperview];
    if(self.host&&self.parent&&self.host.superview==self.parent&&self.originalFrame)self.host.frame=self.originalFrame.CGRectValue;
    [self restoreClipping];
    if(!self.container){self.container=[[PGEdgeCardContainer alloc]initWithFrame:targetWindow.bounds];self.container.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.container.backgroundColor=UIColor.clearColor;self.container.userInteractionEnabled=YES;self.container.card=self.card;}
    self.window=targetWindow;[self.window addSubview:self.container];[self.container addSubview:self.card];self.container.frame=self.window.bounds;
    self.card.frame=target;self.card.hidden=NO;self.card.deferNativeGrabberDismissal=NO;self.docked=YES;
    if(self.chevron)self.chevron.hidden=YES;[self.window bringSubviewToFront:self.container];[self.card startUpdating];[self.card setNeedsLayout];
    if(self.grabber)objc_setAssociatedObject(self.grabber,PGPinnedCardGuardKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)hide {
    self.held=NO;self.releaseGrace=0.0;
    if(self.grabber)objc_setAssociatedObject(self.grabber,PGPinnedCardGuardKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.card stopUpdating];[self.card removeFromSuperview];[self.container removeFromSuperview];
    if(self.host&&self.parent&&self.host.superview==self.parent&&self.originalFrame)self.host.frame=self.originalFrame.CGRectValue;
    [self restoreClips];if(self.chevron&&self.hasChevronState)self.chevron.hidden=self.chevronWasHidden;
    self.card.deferNativeGrabberDismissal=NO;self.card=nil;self.container=nil;self.host=nil;self.parent=nil;self.window=nil;self.sourceWindow=nil;self.chevron=nil;self.grabber=nil;self.originalFrame=nil;self.anchorRect=nil;self.hasChevronState=NO;self.docked=NO;
}
@end

static void PGPreferencesChanged(CFNotificationCenterRef center,void *observer,CFStringRef name,const void*object,CFDictionaryRef info){dispatch_async(dispatch_get_main_queue(),^{[PerfectGrabberPreferences.sharedPreferences reload];if(!PerfectGrabberPreferences.sharedPreferences.isEnabled)[[PGNativeCardHost shared]hide];else [[PGNativeCardHost shared]refresh];});}
%group PerfectGrabberHooks
%hook SBGrabberTongue
- (void)_willPresent{%orig;[PerfectGrabberPreferences.sharedPreferences reload];if(!PerfectGrabberPreferences.sharedPreferences.isEnabled){[[PGNativeCardHost shared]hide];return;}if(!PGIsTopEdgeGrabber(self))return;UIView*host=PGTongueView(self);if(host.window)[[PGNativeCardHost shared]show:host chevron:PGTongueChevron(self) grabber:self];}
- (void)_willDismiss{
    PGNativeCardHost *state=[PGNativeCardHost shared];
    %orig;
    __weak PGNativeCardHost *weakState=state;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.28*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[weakState dockSameCardAfterDismiss];});
}
%end
%end
%ctor{@autoreleasepool{if(![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"])return;Class cls=NSClassFromString(@"SBGrabberTongue");if(cls&&class_getInstanceMethod(cls,@selector(_willPresent))&&class_getInstanceMethod(cls,@selector(_willDismiss))){PGOriginalTongueWillDismissIMP=method_getImplementation(class_getInstanceMethod(cls,@selector(_willDismiss)));%init(PerfectGrabberHooks,SBGrabberTongue=cls);}dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[PerfectGrabberPreferences.sharedPreferences reload];CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),NULL,PGPreferencesChanged,(__bridge CFStringRef)PGPreferencesChangedNotification,NULL,CFNotificationSuspensionBehaviorDeliverImmediately);});}}
