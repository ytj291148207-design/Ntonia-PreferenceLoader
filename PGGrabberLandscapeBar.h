#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 横屏常驻的时间电量块。
/// 与下拉覆盖层完全解耦：不依赖 SBGrabberTongue 的呈现/消失，只要界面进入横屏就常驻显示。
@interface PGLandscapeBar : NSObject

+ (instancetype)sharedBar;

/// 按当前偏好（主开关 + 横屏常驻开关）重算显示状态，并启停轮询。
- (void)reloadPreferences;

/// 立即按当前方向重算一次显示状态。方向服务回调、设置变更后都走这里。
- (void)refreshNow;

/// 下拉面板呈现期间临时收起，避免与舌头上的信息重复显示。
- (void)setSuspended:(BOOL)suspended;

/// 从系统下拉信息卡片长按歌词时，弹出同一套音乐控制面板。
- (void)showControlPanelForPullDown;

@end

NS_ASSUME_NONNULL_END
