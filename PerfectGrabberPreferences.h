#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PGPreferencesDomain;
FOUNDATION_EXPORT NSString *const PGPreferencesChangedNotification;

@interface PerfectGrabberPreferences : NSObject

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL vibrationFeedback;
@property (nonatomic, readonly) BOOL disable24Hour;
@property (nonatomic, readonly) BOOL chargingIcon;
@property (nonatomic, readonly) CGFloat fontSize;
@property (nonatomic, readonly) UIColor *textColor;
@property (nonatomic, readonly) CGFloat cardWidth;
@property (nonatomic, readonly) CGFloat cardScale;
@property (nonatomic, readonly) CGFloat cardBlur;
@property (nonatomic, readonly) CGFloat cardOpacity;
@property (nonatomic, readonly) CGFloat cardCornerRadius;
/// 0 = 统一圆角 / 1 = 收起强制胶囊 / 2 = 全部半高胶囊 / 3 = 小圆角。
@property (nonatomic, readonly) NSInteger cornerStyle;
@property (nonatomic, readonly) NSInteger backgroundMode;

+ (instancetype)sharedPreferences;
+ (UIColor *)colorFromHexString:(NSString *)value fallback:(UIColor *)fallback;
- (void)reload;

@end

NS_ASSUME_NONNULL_END
