#import <UIKit/UIKit.h>

@interface PGGrabberOverlayView : UIView
- (void)startUpdating;
- (void)stopUpdating;
- (void)refreshAppearance;
/// 按当前内容与字号算出贴合文字的尺寸，供横屏常驻块这类需要自适应宽度的宿主使用。
- (CGSize)preferredContentSizeForMaxWidth:(CGFloat)maxWidth;

/// 强制单排显示：时间、电量（以及音乐）全部挤在一条线上，忽略「双行显示」偏好。横屏块用。
@property (nonatomic, assign) BOOL forceSingleLine;

/// 背景色覆盖。非 nil 时优先于偏好里的背景设置（横屏块的自定义色走这里）。
@property (nonatomic, strong, nullable) UIColor *backgroundOverrideColor;

/// 设置音乐区。visible=NO 时整块收起，胶囊缩回时间电量大小。
- (void)setMusicVisible:(BOOL)visible title:(nullable NSString *)title
                 artist:(nullable NSString *)artist playing:(BOOL)playing;

/// 音乐区当前是否展开（横屏块据此决定点按是否弹面板）。
@property (nonatomic, assign, readonly) BOOL musicVisible;

/// 胶囊内容宽度变化（音乐出现/消失、歌名变长）时回调，宿主据此重排。
@property (nonatomic, copy, nullable) void (^contentWidthDidChange)(void);

/// 下拉卡片被长按时调用，由宿主弹出原有音乐控制面板。
@property (nonatomic, copy, nullable) void (^onMusicLongPress)(void);
/// 长按手势结束/取消时通知宿主，以保护系统的抬手收起回调。
@property (nonatomic, copy, nullable) void (^onMusicLongPressEnded)(void);
/// 让宿主上的单击识别器等待本卡片长按失败，避免长按途中先收起下拉卡片。
- (void)deferAncestorTapRecognizersToAllowLongPress;
@end
