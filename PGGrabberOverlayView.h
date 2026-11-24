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

@property (nonatomic, assign, readonly, getter=isExpanded) BOOL expanded;

/// Called when the close button is tapped. If unset, the card removes itself.
@property (nonatomic, copy, nullable) void (^onClose)(void);
/// Called when the preferred height changes (including expansion, scale or width changes).
@property (nonatomic, copy, nullable) void (^onHeightChange)(CGFloat height);

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
/// Returns the compact or expanded card height for the supplied width.
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)startUpdating;
- (void)stopUpdating;
- (void)refreshAppearance;

@end

NS_ASSUME_NONNULL_END
