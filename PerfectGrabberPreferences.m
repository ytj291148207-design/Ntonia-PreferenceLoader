#import "PerfectGrabberPreferences.h"

NSString *const PGPreferencesDomain = @"com.netskao.perfectgrabber";
NSString *const PGPreferencesChangedNotification = @"com.netskao.perfectgrabber.settingschanged";

@interface PerfectGrabberPreferences ()
@property (nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property (nonatomic, readwrite) BOOL vibrationFeedback;
@property (nonatomic, readwrite) BOOL showOnSwipeUp;
@property (nonatomic, readwrite) BOOL landscapeAlwaysOn;
@property (nonatomic, readwrite) BOOL landscapeMusic;
@property (nonatomic, readwrite) BOOL landscapeMetrics;
@property (nonatomic, readwrite) BOOL landscapeMetricsUsage;
@property (nonatomic, readwrite) BOOL landscapeAppFilterEnabled;
@property (nonatomic, readwrite) CGFloat landscapePanelScale;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *landscapeAppAllowList;
@property (nonatomic, readwrite) BOOL landscapeCustomBackground;
@property (nonatomic, readwrite) UIColor *landscapeBackgroundColor;
@property (nonatomic, readwrite) BOOL disable24Hour;
@property (nonatomic, readwrite) BOOL chargingIcon;
@property (nonatomic, readwrite) BOOL twoLine;
@property (nonatomic, readwrite) NSInteger grabberStyle;
@property (nonatomic, readwrite) CGFloat fontSize;
@property (nonatomic, readwrite) NSInteger fontStyle;
@property (nonatomic, readwrite) BOOL backgroundColorEnabled;
@property (nonatomic, readwrite) BOOL swipeUpBackgroundColorEnabled;
@property (nonatomic, readwrite) UIColor *textColor;
@property (nonatomic, readwrite) UIColor *backgroundColor;
@property (nonatomic, readwrite) UIColor *swipeUpBackgroundColor;
@end

@implementation PerfectGrabberPreferences

+ (instancetype)sharedPreferences {
    static PerfectGrabberPreferences *preferences;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        preferences = [[self alloc] init];
        [preferences reload];
    });
    return preferences;
}

- (id)valueForKey:(NSString *)key fallback:(id)fallback {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)PGPreferencesDomain);
    return CFBridgingRelease(value) ?: fallback;
}

+ (UIColor *)colorFromHexString:(NSString *)value fallback:(UIColor *)fallback {
    if (![value isKindOfClass:NSString.class]) return fallback;
    NSString *hex = [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                     stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return fallback;

    unsigned long long rgba = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexLongLong:&rgba] || !scanner.isAtEnd) return fallback;
    CGFloat alpha = hex.length == 8 ? ((rgba >> 24) & 0xff) / 255.0 : 1.0;
    CGFloat red = ((rgba >> 16) & 0xff) / 255.0;
    CGFloat green = ((rgba >> 8) & 0xff) / 255.0;
    CGFloat blue = (rgba & 0xff) / 255.0;
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

- (void)reload {
    NSString *migrationKey = @"PGRestoredLegacySingleLine";
    if (![[self valueForKey:migrationKey fallback:@NO] boolValue]) {
        CFPreferencesSetAppValue(CFSTR("TwoLine"), kCFBooleanFalse,
                                 (__bridge CFStringRef)PGPreferencesDomain);
        CFPreferencesSetAppValue((__bridge CFStringRef)migrationKey, kCFBooleanTrue,
                                 (__bridge CFStringRef)PGPreferencesDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)PGPreferencesDomain);
    }
    // 1.1-16 起「横屏块换边」与「方向诊断弹窗」两个开关被彻底移除（横屏固定贴顶边居中）。
    // 用户机器上这两个键可能还是 true，清成 false，免得以后恢复相关逻辑时又被旧值阴到。
    NSString *placementKey = @"PGPlacementRevision";
    if ([[self valueForKey:placementKey fallback:@0] integerValue] < 3) {
        CFPreferencesSetAppValue(CFSTR("LandscapeFlipSide"), kCFBooleanFalse,
                                 (__bridge CFStringRef)PGPreferencesDomain);
        CFPreferencesSetAppValue(CFSTR("DebugAlertEnabled"), kCFBooleanFalse,
                                 (__bridge CFStringRef)PGPreferencesDomain);
        CFPreferencesSetAppValue((__bridge CFStringRef)placementKey,
                                 (__bridge CFPropertyListRef)@3,
                                 (__bridge CFStringRef)PGPreferencesDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)PGPreferencesDomain);
    }
    self.enabled = [[self valueForKey:@"EnabledPerfectGrabber" fallback:@NO] boolValue];
    self.vibrationFeedback = [[self valueForKey:@"VibrationFeedback" fallback:@YES] boolValue];
    self.showOnSwipeUp = [[self valueForKey:@"ShowOnSwipeUp" fallback:@YES] boolValue];
    self.landscapeAlwaysOn = [[self valueForKey:@"LandscapeAlwaysOn" fallback:@YES] boolValue];
    self.landscapeMusic = [[self valueForKey:@"LandscapeMusic" fallback:@YES] boolValue];
    self.landscapeMetrics = [[self valueForKey:@"LandscapeMetrics" fallback:@YES] boolValue];
    self.landscapeMetricsUsage = [[self valueForKey:@"LandscapeMetricsUsage" fallback:@YES] boolValue];
    self.landscapeAppFilterEnabled = [[self valueForKey:@"LandscapeAppFilterEnabled" fallback:@NO] boolValue];
    // 默认 1.8 倍：156×76 的 1/3 版被反馈"太小"，1.8 倍约 281×137，介于"小巧"和"原来那个大块"之间。
    double panelScale = [[self valueForKey:@"LandscapePanelScale" fallback:@1.8] doubleValue];
    if (!isfinite(panelScale) || panelScale <= 0.0) panelScale = 1.8;
    self.landscapePanelScale = MAX(0.8, MIN(3.0, panelScale));
    id allowList = [self valueForKey:@"LandscapeAppAllowList" fallback:@[]];
    self.landscapeAppAllowList = [allowList isKindOfClass:[NSArray class]] ? allowList : @[];
    self.landscapeCustomBackground = [[self valueForKey:@"LandscapeCustomBackground" fallback:@NO] boolValue];
    self.landscapeBackgroundColor =
        [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"LandscapeBackgroundColor" fallback:@"#00BFFF"]
                                             fallback:[UIColor colorWithRed:0 green:0.75 blue:1 alpha:1]];
    self.disable24Hour = [[self valueForKey:@"Disable24H" fallback:@NO] boolValue];
    self.chargingIcon = [[self valueForKey:@"ChargingIcon" fallback:@YES] boolValue];
    self.twoLine = [[self valueForKey:@"TwoLine" fallback:@NO] boolValue];
    self.grabberStyle = MAX(0, MIN(2, [[self valueForKey:@"GrabberStyle" fallback:@0] integerValue]));
    self.fontSize = MAX(8.0, MIN(28.0, [[self valueForKey:@"FontSize" fallback:@12.0] doubleValue]));
    self.fontStyle = MAX(0, MIN(2, [[self valueForKey:@"FontStyle" fallback:@0] integerValue]));
    self.backgroundColorEnabled = [[self valueForKey:@"EnabledBackgroundColor" fallback:@NO] boolValue];
    self.swipeUpBackgroundColorEnabled = [[self valueForKey:@"EnabledSwipeUpBackgroundColor" fallback:@NO] boolValue];
    self.textColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"TextColor" fallback:@"#FFFFFF"]
                                                           fallback:UIColor.whiteColor];
    self.backgroundColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"BackgroundColor" fallback:@"#00BFFF"]
                                                                 fallback:[UIColor colorWithRed:0 green:0.75 blue:1 alpha:1]];
    self.swipeUpBackgroundColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"SwipeUpBackgroundColor" fallback:@"#00ADFF"]
                                                                        fallback:[UIColor colorWithRed:0 green:0.68 blue:1 alpha:1]];
}

@end
