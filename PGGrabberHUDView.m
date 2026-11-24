#import "PGGrabberHUDView.h"
#import "PerfectGrabberPreferences.h"
#import <math.h>

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (NSInteger)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
@end

@interface PGGrabberHUDView ()
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation PGGrabberHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;

    _panelView = [UIView new];
    _panelView.userInteractionEnabled = NO;
    _panelView.backgroundColor = UIColor.clearColor;
    _panelView.layer.cornerRadius = 10.0;
    _panelView.clipsToBounds = YES;
    [self addSubview:_panelView];

    _blurView = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _blurView.userInteractionEnabled = NO;
    [_panelView addSubview:_blurView];

    _valueLabel = [UILabel new];
    _valueLabel.userInteractionEnabled = NO;
    _valueLabel.textAlignment = NSTextAlignmentCenter;
    _valueLabel.textColor = UIColor.whiteColor;
    _valueLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightMedium];
    _valueLabel.adjustsFontSizeToFitWidth = YES;
    _valueLabel.minimumScaleFactor = 0.75;
    _valueLabel.numberOfLines = 1;
    [_panelView addSubview:_valueLabel];
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (NSInteger)currentBatteryPercentage {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(batteryCapacityAsPercentage)]) {
            return MAX(0, MIN(100, [controller batteryCapacityAsPercentage]));
        }
    }
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    CGFloat level = UIDevice.currentDevice.batteryLevel;
    return level < 0 ? 0 : (NSInteger)lround(level * 100.0);
}

- (BOOL)isCharging {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(isOnAC)]) return [controller isOnAC];
    }
    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

- (UIFont *)configuredFont {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (preferences.fontStyle == 1) {
        return [UIFont systemFontOfSize:preferences.fontSize weight:UIFontWeightBold];
    }
    UIFont *font = [UIFont systemFontOfSize:preferences.fontSize weight:UIFontWeightRegular];
    if (preferences.fontStyle == 2) {
        UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
        if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:preferences.fontSize];
    }
    return font;
}

- (void)refreshAppearance {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    self.valueLabel.font = [self configuredFont];
    self.valueLabel.textColor = preferences.textColor;
    self.blurView.hidden = preferences.swipeUpBackgroundColorEnabled;
    self.panelView.backgroundColor = preferences.swipeUpBackgroundColorEnabled
        ? preferences.swipeUpBackgroundColor
        : UIColor.clearColor;
    [self setNeedsLayout];
}

- (void)updateContents {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSDate *now = NSDate.date;

    NSDateFormatter *timeFormatter = [NSDateFormatter new];
    timeFormatter.locale = NSLocale.currentLocale;
    timeFormatter.dateFormat = preferences.disable24Hour ? @"h:mm a" : @"HH:mm";
    NSString *time = [timeFormatter stringFromDate:now];
    NSString *chargingPrefix = preferences.chargingIcon && [self isCharging] ? @"\u26A1 " : @"";
    self.valueLabel.text = [NSString stringWithFormat:@"%@ / %@%ld%%", time, chargingPrefix,
                            (long)[self currentBatteryPercentage]];
    [self refreshAppearance];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat contentWidth = ceil([self.valueLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 48.0)].width) + 24.0;
    self.panelView.bounds = CGRectMake(0.0, 0.0, MIN(220.0, MAX(150.0, contentWidth)), 48.0);
    self.panelView.center = CGPointMake(width / 2.0, height / 2.0);

    UIWindow *window = self.window;
    if (window) {
        id<UICoordinateSpace> screenSpace = window.screen.coordinateSpace;
        CGPoint origin = [window convertPoint:CGPointZero toCoordinateSpace:screenSpace];
        CGPoint xAxis = [window convertPoint:CGPointMake(1.0, 0.0) toCoordinateSpace:screenSpace];
        CGFloat angle = atan2(xAxis.y - origin.y, xAxis.x - origin.x);
        self.panelView.transform = CGAffineTransformMakeRotation(-angle);
    } else {
        self.panelView.transform = CGAffineTransformIdentity;
    }
    self.blurView.frame = self.panelView.bounds;
    self.valueLabel.frame = CGRectInset(self.panelView.bounds, 12.0, 0.0);
}

- (void)startUpdating {
    [self stopUpdating];
    [self refreshAppearance];
    [self updateContents];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                selector:@selector(updateContents)
                                                userInfo:nil repeats:YES];
}

- (void)stopUpdating {
    [self.timer invalidate];
    self.timer = nil;
}

@end
