#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Edge-docked media/status card. The SpringBoard host manages its position and size.
@interface PGGrabberOverlayView : UIView

/// Scales the card's internal geometry and preferred width/height (clamped to 0.65–1.60).
@property (nonatomic, assign) CGFloat cardScale;
/// Visual-effect strength, 0.0–1.0. This changes the blur view's alpha.
@property (nonatomic, assign) CGFloat blurAmount;
/// Dark tint opacity over the blur, 0.0–1.0.
@property (nonatomic, assign) CGFloat backgroundOpacity;
/// Corner radius in points at cardScale == 1.0; it scales with cardScale.
@property (nonatomic, assign) CGFloat cornerRadius;
/// 圆角策略：0 统一 / 1 收起强制胶囊 / 2 全部半高 / 3 小圆角。半径始终会被夹到不超过半高。
@property (nonatomic, assign) NSInteger cornerStyle;


/// Called when the close button is tapped.
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onLongPressStateChange)(BOOL active);
@property (nonatomic, assign) BOOL compactMode;
@property (nonatomic, assign) BOOL deferNativeGrabberDismissal;
@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;
/// Called when expansion changes so the edge host can resize its window.
@property (nonatomic, copy, nullable) void (^onHeightChange)(CGFloat height);
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
/// Returns the compact or expanded card height for the supplied width.
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)startUpdating;
- (void)stopUpdating;
- (void)refreshAppearance;

@end

NS_ASSUME_NONNULL_END
