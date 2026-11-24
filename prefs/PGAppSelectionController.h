#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 选择"横屏块只在这些 App 里生效"的白名单。
/// 直接由设置页 push 进来，勾选结果即时写进偏好并发跨进程通知，
/// SpringBoard 那边下一次轮询（0.25s）就会生效，不需要 respring。
@interface PGAppSelectionController : UIViewController

@end

NS_ASSUME_NONNULL_END
