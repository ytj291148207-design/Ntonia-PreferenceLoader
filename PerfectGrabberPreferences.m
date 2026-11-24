#import "PerfectGrabberPreferences.h"

NSString *const PGPreferencesDomain = @"com.netskao.perfectgrabber";
NSString *const PGPreferencesChangedNotification = @"com.netskao.perfectgrabber.settingschanged";

@interface PerfectGrabberPreferences ()
@property (nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property (nonatomic, readwrite) BOOL vibrationFeedback;
@property (nonatomic, readwrite) BOOL disable24Hour;
@property (nonatomic, readwrite) BOOL chargingIcon;
@property (nonatomic, readwrite) CGFloat fontSize;
@property (nonatomic, readwrite) NSInteger fontStyle;
@property (nonatomic, readwrite) UIColor *textColor;
@property (nonatomic, readwrite) CGFloat cardWidth;
@property (nonatomic, readwrite) CGFloat cardScale;
@property (nonatomic, readwrite) CGFloat cardBlur;
@property (nonatomic, readwrite) CGFloat cardOpacity;
@property (nonatomic, readwrite) CGFloat cardCornerRadius;
@property (nonatomic, readwrite) UIColor *cardTintColor;
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
    self.enabled = [[self valueForKey:@"EnabledPerfectGrabber" fallback:@NO] boolValue];
    self.vibrationFeedback = [[self valueForKey:@"VibrationFeedback" fallback:@YES] boolValue];
    self.disable24Hour = [[self valueForKey:@"Disable24H" fallback:@NO] boolValue];
    self.chargingIcon = [[self valueForKey:@"ChargingIcon" fallback:@YES] boolValue];
    self.fontSize = MAX(8.0, MIN(28.0, [[self valueForKey:@"FontSize" fallback:@12.0] doubleValue]));
    self.fontStyle = MAX(0, MIN(2, [[self valueForKey:@"FontStyle" fallback:@0] integerValue]));
    self.textColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"TextColor" fallback:@"#FFFFFF"]
                                                           fallback:UIColor.whiteColor];
    self.cardWidth = MAX(300.0, MIN(900.0, [[self valueForKey:@"CardWidth" fallback:@720.0] doubleValue]));
    self.cardScale = MAX(0.7, MIN(1.6, [[self valueForKey:@"CardScale" fallback:@1.0] doubleValue]));
    self.cardBlur = MAX(0.0, MIN(1.0, [[self valueForKey:@"CardBlur" fallback:@0.82] doubleValue]));
    self.cardOpacity = MAX(0.05, MIN(1.0, [[self valueForKey:@"CardOpacity" fallback:@0.78] doubleValue]));
    self.cardCornerRadius = MAX(0.0, MIN(48.0, [[self valueForKey:@"CardCornerRadius" fallback:@22.0] doubleValue]));
    self.cardTintColor = [PerfectGrabberPreferences colorFromHexString:[self valueForKey:@"CardTintColor" fallback:@"#20000000"] fallback:[UIColor colorWithWhite:0 alpha:0.12]];
}

@end
