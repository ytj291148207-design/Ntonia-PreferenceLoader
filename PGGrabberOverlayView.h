#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Docked media/status card. The host owns its edge-attached UIWindow and is
/// responsible for resizing/repositioning that window when the card height changes.
@interface PGGrabberOverlayView : UIView

/// Scales the card's internal geometry and preferred width/height (clamped to 0.65–1.50).
@property (nonatomic, assign) CGFloat cardScale;
/// Visual-effect strength, 0.0–1.0. This changes the blur view's alpha.
@property (nonatomic, assign) CGFloat blurAmount;
/// Dark tint opacity over the blur, 0.0–1.0.
@property (nonatomic, assign) CGFloat backgroundOpacity;
/// Corner radius in points at cardScale == 1.0; it scales with cardScale.
@property (nonatomic, assign) CGFloat cornerRadius;


/// Called when the close button is tapped.
@property (nonatomic, copy, nullable) void (^onClose)(void);
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
