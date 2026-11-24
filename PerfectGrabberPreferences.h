#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PGPreferencesDomain;
FOUNDATION_EXPORT NSString *const PGPreferencesChangedNotification;

@interface PerfectGrabberPreferences : NSObject

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL vibrationFeedback;
@property (nonatomic, readonly) BOOL showOnSwipeUp;
@property (nonatomic, readonly) BOOL landscapeAlwaysOn;
/// 横屏块是否附带"正在播放的音乐"信息（前台是游戏/别的 App、后台在放歌时）。
@property (nonatomic, readonly) BOOL landscapeMusic;
/// 时间前面是否加"CPU 频率 + 电池温度"。
@property (nonatomic, readonly) BOOL landscapeMetrics;
/// 指标区显示 CPU 占用率（YES，默认，实时跳动）还是芯片最高频率（NO，读不到真实瞬时频率）。
@property (nonatomic, readonly) BOOL landscapeMetricsUsage;
/// 只对白名单里的 App 生效（YES）。关闭时任何 App 横屏都显示。
@property (nonatomic, readonly) BOOL landscapeAppFilterEnabled;
/// 白名单（bundle identifier 数组）。只在 landscapeAppFilterEnabled 为 YES 时有意义。
@property (nonatomic, copy, readonly) NSArray<NSString *> *landscapeAppAllowList;
/// 播放面板的缩放倍数：1.0 = 156×76 的紧凑版，最大 3.0 ≈ 468×228（≈ 最初那版大小）。
@property (nonatomic, readonly) CGFloat landscapePanelScale;
/// 横屏块使用独立的自定义背景色，不再跟随上面那组"背景"设置。
@property (nonatomic, readonly) BOOL landscapeCustomBackground;
@property (nonatomic, readonly) UIColor *landscapeBackgroundColor;
@property (nonatomic, readonly) BOOL disable24Hour;
@property (nonatomic, readonly) BOOL chargingIcon;
@property (nonatomic, readonly) BOOL twoLine;
@property (nonatomic, readonly) NSInteger grabberStyle;
@property (nonatomic, readonly) CGFloat fontSize;
@property (nonatomic, readonly) NSInteger fontStyle;
@property (nonatomic, readonly) BOOL backgroundColorEnabled;
@property (nonatomic, readonly) BOOL swipeUpBackgroundColorEnabled;
@property (nonatomic, readonly) UIColor *textColor;
@property (nonatomic, readonly) UIColor *backgroundColor;
@property (nonatomic, readonly) UIColor *swipeUpBackgroundColor;

+ (instancetype)sharedPreferences;
+ (UIColor *)colorFromHexString:(NSString *)value fallback:(UIColor *)fallback;
- (void)reload;

@end

NS_ASSUME_NONNULL_END
