#import "PGGrabberOverlayView.h"
#import "PGHardwareMetrics.h"
#import "PGNowPlaying.h"
#import "PerfectGrabberPreferences.h"
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <float.h>

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (NSInteger)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
@end

/// 在高度 y 处，圆角矩形左边界到 view 左沿的水平距离。
/// 胶囊卡片如果只给固定 padding，文字会压在端部的圆弧上（截图里 19:53 就是这样被切的）。
static CGFloat PGRadiusInset(CGFloat y, CGFloat height, CGFloat radius) {
    if (radius <= 0.5 || height <= 0.0) return 0.0;
    CGFloat r = MIN(radius, height * 0.5);
    CGFloat dy = 0.0;
    if (y < r) dy = r - y;
    else if (y > height - r) dy = y - (height - r);
    else return 0.0;
    CGFloat inner = sqrt(MAX(0.0, r * r - dy * dy));
    return MAX(0.0, r - inner);
}

/// 一段内容（minY...maxY）要在圆角矩形内完整可见，左右各需要让出多少。
/// 取上下两端内缩的较大值：只用中心高度算，顶边会伸进弧线里被切掉。
static CGFloat PGFrameInset(CGFloat minY, CGFloat maxY, CGFloat height, CGFloat radius) {
    return MAX(PGRadiusInset(minY, height, radius), PGRadiusInset(maxY, height, radius));
}

static CGFloat PGClamp(CGFloat value, CGFloat minimum, CGFloat maximum) {
    if (!isfinite(value)) return minimum;
    return MIN(maximum, MAX(minimum, value));
}

@interface PGGrabberOverlayView () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *tintView;
@property (nonatomic, strong) UIView *gaussianBlurBackdrop;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *batteryLabel;
@property (nonatomic, strong) UILabel *temperatureLabel;
@property (nonatomic, strong) UILabel *cpuLabel;
@property (nonatomic, strong) UIButton *closeButton; // chevron: expand/collapse
@property (nonatomic, strong) UIButton *dismissButton; // xmark: remove the card
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *artworkFallbackLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *lyricsLabel;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UILongPressGestureRecognizer *cardLongPress;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSData *displayedArtworkData;
@property (nonatomic, copy) NSString *currentLyricKey;
@property (nonatomic, copy) NSString *currentLyrics;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *lyricsCache;
@property (nonatomic, strong) NSURLSessionDataTask *lyricsTask;
@property (nonatomic, assign) NSUInteger lyricsRequestGeneration;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, assign, readwrite, getter=isExpanded) BOOL expanded;
@property (nonatomic, assign) BOOL hasPendingPlaybackState;
@property (nonatomic, assign) BOOL pendingPlaybackState;
@property (nonatomic, strong) NSDate *pendingPlaybackDeadline;
@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, assign) BOOL isSeeking;
@property (nonatomic, assign) double displayedSeekElapsed;
@property (nonatomic, assign) NSInteger lastHapticStep;
@property (nonatomic, assign) NSInteger seekDetentCount;
@property (nonatomic, strong) UISelectionFeedbackGenerator *seekHaptics;
@property (nonatomic, assign) BOOL vibrationFeedbackEnabled;
@property (nonatomic, copy) NSString *compactStatusText;
@property (nonatomic, copy) NSString *compactTrackText;
- (UILabel *)newLabelWithWeight:(UIFontWeight)weight alignment:(NSTextAlignment)alignment;
- (UIButton *)buttonWithSymbol:(NSString *)symbol fallback:(NSString *)fallback accessibility:(NSString *)accessibility;
- (void)updateContents;
@end

@implementation PGGrabberOverlayView

// Ensure the explicit × dismiss target wins over the long-press recognizer and
// remains easy to hit even when compact mode scales the visible glyph down.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.hidden && self.userInteractionEnabled && !self.dismissButton.hidden) {
        // Keep the neighboring chevron's own hit area intact; expand only the
        // remaining margin around the visible × dismissal control.
        if (!self.closeButton.hidden && CGRectContainsPoint(self.closeButton.frame, point)) {
            return [super hitTest:point withEvent:event];
        }
        CGRect dismissHit = CGRectInset(self.dismissButton.frame, -6.0, -6.0);
        if (CGRectContainsPoint(dismissHit, point)) return self.dismissButton;
    }
    return [super hitTest:point withEvent:event];
}

@synthesize cardScale = _cardScale;
@synthesize blurAmount = _blurAmount;
@synthesize backgroundOpacity = _backgroundOpacity;
@synthesize cornerRadius = _cornerRadius;
@synthesize cardHeightScale = _cardHeightScale;
@synthesize fontWeight = _fontWeight;
@synthesize longPressControls = _longPressControls;
@synthesize lyricsLookupEnabled = _lyricsLookupEnabled;
@synthesize cornerStyle = _cornerStyle;
@synthesize expanded = _expanded;
@synthesize compactMode = _compactMode;
@synthesize deferNativeGrabberDismissal = _deferNativeGrabberDismissal;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    _cardScale = PGClamp(preferences.cardScale, 0.65, 1.60);
    _blurAmount = PGClamp(preferences.cardBlur, 0.0, 1.0);
    _backgroundOpacity = PGClamp(preferences.cardOpacity, 0.0, 1.0);
    _cornerRadius = PGClamp(preferences.cardCornerRadius, 0.0, 80.0);
    _cornerStyle = MAX(0, MIN(3, preferences.cornerStyle));
    _cardHeightScale = PGClamp(preferences.cardHeightScale, 0.70, 1.60);
    _fontWeight = PGClamp(preferences.fontWeight, 0.0, 1.0);
    _longPressControls = preferences.longPressControls;
    _expanded = !_longPressControls; // 默认收起；可选长按展开。
    _lyricsLookupEnabled = preferences.lyricsLookupEnabled;
    _lyricsCache = [NSMutableDictionary dictionary];
    _seekHaptics = [UISelectionFeedbackGenerator new];
    _seekDetentCount = 30;

    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = YES;
    self.layer.masksToBounds = YES;
    self.vibrationFeedbackEnabled = preferences.vibrationFeedback;
    self.userInteractionEnabled = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;

    UIBlurEffect *effect;
    if (@available(iOS 13.0, *)) {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    } else {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    }
    _blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
    _blurView.userInteractionEnabled = NO;
    [self addSubview:_blurView];
    _gaussianBlurBackdrop = [UIView new];
    _gaussianBlurBackdrop.userInteractionEnabled = NO;
    _gaussianBlurBackdrop.backgroundColor = [UIColor colorWithWhite:0.72 alpha:0.52];
    _gaussianBlurBackdrop.hidden = YES;

    _tintView = [UIView new];
    _tintView.userInteractionEnabled = NO;
    _tintView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:_backgroundOpacity];
    [self addSubview:_tintView];
    [self insertSubview:_gaussianBlurBackdrop belowSubview:_blurView];

    _timeLabel = [self newLabelWithWeight:UIFontWeightSemibold alignment:NSTextAlignmentLeft];
    _timeLabel.adjustsFontSizeToFitWidth = YES;
    _timeLabel.minimumScaleFactor = 0.70;
    [self addSubview:_timeLabel];

    _batteryLabel = [self newLabelWithWeight:UIFontWeightMedium alignment:NSTextAlignmentCenter];
    _temperatureLabel = [self newLabelWithWeight:UIFontWeightRegular alignment:NSTextAlignmentCenter];
    _cpuLabel = [self newLabelWithWeight:UIFontWeightRegular alignment:NSTextAlignmentCenter];
    for (UILabel *label in @[_batteryLabel, _temperatureLabel, _cpuLabel]) {
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.60;
        [self addSubview:label];
    }

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *closeImage = [UIImage systemImageNamed:@"xmark"];
    if (closeImage) [_closeButton setImage:closeImage forState:UIControlStateNormal];
    else [_closeButton setTitle:@"×" forState:UIControlStateNormal];
    _closeButton.accessibilityLabel = @"关闭卡片";
    _closeButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _closeButton.layer.cornerRadius = 10.0;
    _closeButton.clipsToBounds = YES;   // 底色先裁成正圆，避免方角被卡片圆弧切掉
    _closeButton.tintColor = UIColor.whiteColor;
    UIImage *initialArrow = [UIImage systemImageNamed:@"chevron.down"];
    if (initialArrow) [_closeButton setImage:initialArrow forState:UIControlStateNormal]; else [_closeButton setTitle:@"⌄" forState:UIControlStateNormal];
    _closeButton.accessibilityLabel = @"展开卡片内容";
    [_closeButton addTarget:self action:@selector(toggleExpandedTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeButton];

    _dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *dismissImage = [UIImage systemImageNamed:@"xmark"];
    if (dismissImage) [_dismissButton setImage:dismissImage forState:UIControlStateNormal];
    else [_dismissButton setTitle:@"×" forState:UIControlStateNormal];
    _dismissButton.accessibilityLabel = @"关闭卡片";
    _dismissButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    _dismissButton.layer.cornerRadius = 12.0;
    _dismissButton.clipsToBounds = YES;
    _dismissButton.tintColor = UIColor.whiteColor;
    [_dismissButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_dismissButton];

    _artworkView = [UIImageView new];
    _artworkView.contentMode = UIViewContentModeScaleAspectFill;
    _artworkView.clipsToBounds = YES;
    _artworkView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [self addSubview:_artworkView];
    _artworkFallbackLabel = [self newLabelWithWeight:UIFontWeightRegular alignment:NSTextAlignmentCenter];
    _artworkFallbackLabel.text = @"♫";
    [self addSubview:_artworkFallbackLabel];

    _titleLabel = [self newLabelWithWeight:UIFontWeightSemibold alignment:NSTextAlignmentLeft];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.text = @"暂无播放内容";
    [self addSubview:_titleLabel];
    _artistLabel = [self newLabelWithWeight:UIFontWeightRegular alignment:NSTextAlignmentLeft];
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistLabel.text = @"—";
    [self addSubview:_artistLabel];
    _lyricsLabel = [self newLabelWithWeight:UIFontWeightRegular alignment:NSTextAlignmentLeft];
    _lyricsLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.66];
    _lyricsLabel.text = @"暂无歌词";
    [self addSubview:_lyricsLabel];
    _progressSlider = [UISlider new];
    _progressSlider.minimumValue=0; _progressSlider.maximumValue=1;
    _progressSlider.minimumTrackTintColor=UIColor.whiteColor;
    _progressSlider.maximumTrackTintColor=[UIColor colorWithWhite:1 alpha:0.3];
    _progressSlider.thumbTintColor=UIColor.whiteColor; _progressSlider.hidden=YES;
    [_progressSlider addTarget:self action:@selector(progressBegan:) forControlEvents:UIControlEventTouchDown];
    [_progressSlider addTarget:self action:@selector(progressChanged:) forControlEvents:UIControlEventValueChanged];
    [_progressSlider addTarget:self action:@selector(progressEnded:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    [self addSubview:_progressSlider];

    _elapsedLabel = [self newLabelWithWeight:UIFontWeightRegular alignment:NSTextAlignmentLeft];
    _elapsedLabel.text = @"0:00";
    _elapsedLabel.hidden = YES;
    [self addSubview:_elapsedLabel];
    _durationLabel = [self newLabelWithWeight:UIFontWeightRegular alignment:NSTextAlignmentRight];
    _durationLabel.text = @"0:00";
    _durationLabel.hidden = YES;
    [self addSubview:_durationLabel];

    _previousButton = [self buttonWithSymbol:@"backward.end.fill" fallback:@"|◀" accessibility:@"上一首"];
    [_previousButton addTarget:self action:@selector(previousTapped) forControlEvents:UIControlEventTouchUpInside];
    _playPauseButton = [self buttonWithSymbol:@"playpause.fill" fallback:@"▶︎/Ⅱ" accessibility:@"播放或暂停"];
    [_playPauseButton addTarget:self action:@selector(playPauseTapped) forControlEvents:UIControlEventTouchUpInside];
    _nextButton = [self buttonWithSymbol:@"forward.end.fill" fallback:@"▶|" accessibility:@"下一首"];
    [_nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
    for (UIButton *button in @[_previousButton, _playPauseButton, _nextButton]) {
        button.hidden = YES;
        [self addSubview:button];
    }

    _cardLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardLongPress:)];
    _cardLongPress.minimumPressDuration = 0.32;
    _cardLongPress.allowableMovement = 24.0;
    _cardLongPress.cancelsTouchesInView = NO;
    _cardLongPress.delegate = self;
    [self addGestureRecognizer:_cardLongPress];

    [self refreshAppearance];
    [self updateContents];
    return self;
}

- (UILabel *)newLabelWithWeight:(UIFontWeight)weight alignment:(NSTextAlignment)alignment {
    UILabel *label = [UILabel new];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:13.0 weight:weight];
    label.textAlignment = alignment;
    label.numberOfLines = 1;
    label.backgroundColor = UIColor.clearColor;
    return label;
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol fallback:(NSString *)fallback accessibility:(NSString *)accessibility {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *image = [UIImage systemImageNamed:symbol];
    if (image) [button setImage:image forState:UIControlStateNormal];
    else [button setTitle:fallback forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.13];
    button.layer.cornerRadius = 12.0;
    button.accessibilityLabel = accessibility;
    button.hidden = YES;
    return button;
}

- (void)dealloc {
    [_timer invalidate];
}

#pragma mark - Public configuration

- (CGFloat)cardScale { return _cardScale; }
- (void)setCardScale:(CGFloat)value {
    CGFloat next = PGClamp(value, 0.65, 1.60);
    if (fabs(next - _cardScale) < 0.001) return;
    _cardScale = next;
    [self refreshAppearance];
    [self setNeedsLayout];
}

- (CGFloat)blurAmount { return _blurAmount; }
- (void)setBlurAmount:(CGFloat)value {
    _blurAmount = PGClamp(value, 0.0, 1.0);
    [self refreshAppearance];
}

- (CGFloat)backgroundOpacity { return _backgroundOpacity; }
- (void)setBackgroundOpacity:(CGFloat)value {
    _backgroundOpacity = PGClamp(value, 0.0, 1.0);
    [self refreshAppearance];
}

- (NSInteger)cornerStyle { return _cornerStyle; }
- (void)setCornerStyle:(NSInteger)value {
    NSInteger next = MAX(0, MIN(3, value));
    if (next == _cornerStyle) return;
    _cornerStyle = next;
    [self refreshAppearance];
    [self setNeedsLayout];
}

- (CGFloat)cornerRadius { return _cornerRadius; }
- (void)setCornerRadius:(CGFloat)value {
    _cornerRadius = PGClamp(value, 0.0, 80.0);
    [self refreshAppearance];
    [self setNeedsLayout];
}

- (BOOL)isExpanded { return _expanded; }
- (CGFloat)cardHeightScale { return _cardHeightScale; }
- (void)setCardHeightScale:(CGFloat)value {
    CGFloat next = PGClamp(value, 0.70, 1.60);
    if (fabs(next - _cardHeightScale) < 0.001) return;
    _cardHeightScale = next;
    CGFloat height = [self heightForCurrentWidth];
    if (self.onHeightChange) self.onHeightChange(height);
    else { CGRect f = self.frame; f.size.height = height; self.frame = f; }
    [self setNeedsLayout];
    [self layoutIfNeeded];
}
- (CGFloat)fontWeight { return _fontWeight; }
- (void)setFontWeight:(CGFloat)value {
    _fontWeight = PGClamp(value, 0.0, 1.0);
    [self refreshAppearance];
    [self setNeedsLayout];
}
- (BOOL)longPressControls { return _longPressControls; }
- (void)setLongPressControls:(BOOL)value {
    if (_longPressControls == value) return;
    _longPressControls = value;
    // Setter runs only when the stored option actually changes. Turning off
    // long-press expands controls by default; turning it on returns to compact.
    [self setExpanded:!value animated:YES];
}
- (BOOL)lyricsLookupEnabled { return _lyricsLookupEnabled; }
- (void)setLyricsLookupEnabled:(BOOL)value {
    if (_lyricsLookupEnabled == value) return;
    _lyricsLookupEnabled = value;
    self.lyricsRequestGeneration += 1;
    [self.lyricsTask cancel];
    self.lyricsTask = nil;
    self.currentLyricKey = nil;
    self.currentLyrics = @"暂无歌词";
    [self updateContents];
}
- (BOOL)isCompactMode { return _compactMode; }
- (void)setCompactMode:(BOOL)value { _compactMode=value; [self setNeedsLayout]; }
- (BOOL)deferNativeGrabberDismissal { return _deferNativeGrabberDismissal; }
- (void)setDeferNativeGrabberDismissal:(BOOL)value { _deferNativeGrabberDismissal=value; }

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) return;
    _expanded = expanded;
    CGFloat targetHeight = [self heightForCurrentWidth];
    [self setNeedsLayout];

    // 面板内嵌宿主同步调整高度；不同时自改 frame，避免与 SpringBoard 布局动画争抢。
    if (self.onHeightChange) {
        self.onHeightChange(targetHeight);
        return;
    }
    if (CGRectGetWidth(self.bounds) <= 0.0) { [self layoutIfNeeded]; return; }
    void (^layoutBlock)(void) = ^{
        CGRect frame = self.frame;
        frame.size.height = targetHeight;
        self.frame = frame;
        [self layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.26 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:layoutBlock completion:nil];
    } else {
        layoutBlock();
    }
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat scale = PGClamp(self.cardScale, 0.65, 1.60);
    if (self.compactMode && self.isExpanded) {
        // Landscape media controls use a single horizontal content row plus
        // seek bar; no tall portrait-style stack over the game.
        CGFloat vertical = PGClamp(self.cardHeightScale, 0.70, 1.20);
        return PGClamp(104.0 * vertical * scale, 92.0 * scale, 128.0 * scale);
    }
    CGFloat height = self.compactMode ? 44.0 : (112.0 + (self.isExpanded ? 64.0 * self.cardHeightScale : 0.0));
    return MAX(44.0, height * scale);
}

- (CGFloat)heightForCurrentWidth {
    return [self heightForWidth:CGRectGetWidth(self.bounds)];
}

#pragma mark - Corner radius（唯一入口）

/// 半径永远夹在 [0, 高度/2]：超过半高在视觉上没有任何区别，只会让 CALayer 的连续曲率
/// 在四角被硬切，看起来像"圆角没生效"。所有子视图共用同一个半径，避免出现外圆内方。
- (CGFloat)pgEffectiveCornerRadius {
    CGFloat scale = PGClamp(self.cardScale, 0.65, 1.60);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (height <= 1.0) height = [self heightForWidth:CGRectGetWidth(self.bounds)];
    CGFloat half = MAX(0.0, floor(height * 0.5));
    CGFloat base = MAX(0.0, self.cornerRadius * scale);
    CGFloat radius = base;
    switch (self.cornerStyle) {
        case 1: radius = self.isExpanded ? base : half; break;  // 收起永远正圆，展开跟滑杆
        case 2: radius = half; break;                            // 收起/展开都半高
        case 3: radius = MIN(base, 16.0 * scale); break;         // 小圆角
        default: radius = base; break;                           // 统一
    }
    return MAX(0.0, MIN(radius, half));
}

- (void)pgApplyCornerRadius {
    CGFloat radius = [self pgEffectiveCornerRadius];
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.cornerRadius = radius;
    self.layer.masksToBounds = YES;
    for (UIView *view in @[_blurView, _tintView, _gaussianBlurBackdrop]) {
        if (!view.superview) continue;
        view.layer.cornerCurve = kCACornerCurveContinuous;
        view.layer.cornerRadius = radius;
        view.layer.masksToBounds = YES;
        view.clipsToBounds = YES;
    }
    // 直角时不要再留发丝描边，否则四条边会各多出一条 1px 亮线。
    self.layer.borderWidth = radius > 0.5 ? (1.0 / MAX(UIScreen.mainScreen.scale, 1.0)) : 0.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
}

#pragma mark - Appearance and layout

- (UIFont *)configuredFontWithSize:(CGFloat)size weight:(UIFontWeight)weight {
    // 以前是拿"字体大小"直接当字号用：默认 15 会把 9pt 的状态行撑成 15pt，
    // 结果一排文字把 17pt 的行塞满、被圆角切掉。改成按比例缩放，滑杆仍能整体放大缩小。
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    CGFloat ratio = PGClamp((preferences.fontSize > 0.0 ? preferences.fontSize : 15.0) / 15.0, 0.60, 1.60);
    CGFloat requested = size * self.cardScale * ratio;
    CGFloat userWeight = PGClamp(preferences.fontWeight, 0.0, 1.0);
    CGFloat adjustedWeight = PGClamp((CGFloat)weight + (userWeight - 0.5) * 0.8, UIFontWeightUltraLight, UIFontWeightBlack);
    return [UIFont systemFontOfSize:MAX(7.0, MIN(26.0, requested)) weight:adjustedWeight];
}

- (void)applyAppearance {
    [self refreshAppearance];
}

- (void)refreshAppearance {
    UIColor *textColor = UIColor.whiteColor;
    @try {
        UIColor *preferred = PerfectGrabberPreferences.sharedPreferences.textColor;
        if (preferred) textColor = preferred;
    } @catch (__unused NSException *exception) { }

    CGFloat blur = PGClamp(self.blurAmount, 0.0, 1.0);
    NSInteger mode = PerfectGrabberPreferences.sharedPreferences.backgroundMode;
    UIBlurEffectStyle style = mode == 0 ? UIBlurEffectStyleSystemThinMaterialDark
                              : (mode == 1 ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemChromeMaterialDark);
    if (@available(iOS 13.0, *)) self.blurView.effect = [UIBlurEffect effectWithStyle:style];
    self.blurView.alpha = (0.35 + blur * 0.65) * (mode == 2 ? 0.35 : 1.0);
    self.gaussianBlurBackdrop.hidden = mode != 2;
    self.gaussianBlurBackdrop.backgroundColor = [UIColor colorWithWhite:0.70 alpha:0.18 + blur * 0.48];
    // Keep one predictable dark tint; only the opacity slider controls its strength.
    self.tintView.backgroundColor = [UIColor colorWithWhite:0.0
                                                      alpha:PGClamp(self.backgroundOpacity, 0.0, 1.0)];
    self.blurView.hidden = NO;
    [self pgApplyCornerRadius];
    self.timeLabel.textColor = textColor;
    self.batteryLabel.textColor = textColor;
    self.temperatureLabel.textColor = textColor;
    self.cpuLabel.textColor = textColor;
    self.titleLabel.textColor = textColor;
    self.artistLabel.textColor = [textColor colorWithAlphaComponent:0.88];
    self.lyricsLabel.textColor = [textColor colorWithAlphaComponent:0.64];
    self.artworkFallbackLabel.textColor = textColor;
    self.closeButton.tintColor = textColor;
    self.dismissButton.tintColor = textColor;
    self.dismissButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
    self.dismissButton.layer.borderWidth = 0.5;
    self.dismissButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;

    self.timeLabel.font = [self configuredFontWithSize:14.0 weight:UIFontWeightSemibold];
    for (UILabel *label in @[_batteryLabel, _temperatureLabel, _cpuLabel]) {
        label.font = [self configuredFontWithSize:11.0 weight:UIFontWeightMedium];
    }
    self.titleLabel.font = [self configuredFontWithSize:15.0 weight:UIFontWeightSemibold];
    self.artistLabel.font = [self configuredFontWithSize:12.0 weight:UIFontWeightRegular];
    self.lyricsLabel.font = [self configuredFontWithSize:11.0 weight:UIFontWeightRegular];
    self.artworkFallbackLabel.font = [UIFont systemFontOfSize:25.0 * self.cardScale weight:UIFontWeightLight];
    self.closeButton.layer.cornerRadius = 10.0 * self.cardScale;
    for (UIButton *button in @[_previousButton, _playPauseButton, _nextButton]) {
        button.tintColor = textColor;
        button.layer.cornerRadius = 12.0 * self.cardScale;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat scale = PGClamp(self.cardScale, 0.65, 1.60);
    [self pgApplyCornerRadius];
    self.blurView.frame = self.bounds;
    self.gaussianBlurBackdrop.frame = self.bounds;
    self.tintView.frame = self.bounds;
    // 圆按钮的半径必须正好是边长的一半；超过一半 CALayer 会把圆弧切平（× 和上一首/下一首会变形）
    self.closeButton.layer.cornerRadius = 10.0 * scale;
    for (UIButton *button in @[_previousButton, _playPauseButton, _nextButton]) {
        button.layer.cornerRadius = 12.0 * scale;
    }

    if (self.compactMode) {
        CGFloat radius = [self pgEffectiveCornerRadius];
        CGFloat basePad = 6.0 * scale;
        CGFloat close = 18.0 * scale;
        CGFloat dismiss = 20.0 * scale;
        CGFloat row = 17.0 * scale;
        // 状态行贴着上边，是圆角吃得最狠的一行。必须按整行（顶边到底边）算内缩，
        // 只按中心高度算会让顶边伸进弧线，时间首位数字被切掉。
        CGFloat statusY = 3.0 * scale;
        CGFloat statusInset = basePad + PGFrameInset(statusY, statusY + row, height, radius);
        CGFloat statusRight = MAX(0.0, width - statusInset - close - dismiss - 7.0 * scale);
        CGFloat rowWidth = MAX(0.0, statusRight - statusInset);
        // Keep metrics in one compact row. The previous center gap left a blank
        // block beneath Dynamic Island, so reclaim it for the temperature field.
        CGFloat timeWidth = rowWidth * 0.20;
        CGFloat batteryWidth = rowWidth * 0.25;
        CGFloat temperatureWidth = rowWidth * 0.26;
        CGFloat cpuWidth = MAX(0.0, rowWidth - timeWidth - batteryWidth - temperatureWidth);
        self.timeLabel.frame = CGRectMake(statusInset, statusY, timeWidth, row);
        self.batteryLabel.frame = CGRectMake(statusInset + timeWidth, statusY, batteryWidth, row);
        self.temperatureLabel.frame = CGRectMake(statusInset + timeWidth + batteryWidth, statusY, temperatureWidth, row);
        self.cpuLabel.frame = CGRectMake(statusInset + timeWidth + batteryWidth + temperatureWidth, statusY, cpuWidth, row);
        for (UILabel *label in @[_timeLabel, _batteryLabel, _temperatureLabel, _cpuLabel]) {
            label.font = [self configuredFontWithSize:9.0 weight:UIFontWeightSemibold];
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.35;
            label.textAlignment = NSTextAlignmentCenter;
            label.hidden = NO;
        }
        CGFloat closeInset = PGFrameInset(statusY, statusY + close, height, radius);
        self.closeButton.frame = CGRectMake(width - closeInset - basePad - close - dismiss - 4.0 * scale,
                                            statusY, close, close);
        self.closeButton.hidden = NO;
        UIImage *toggleImage = [UIImage systemImageNamed:(self.isExpanded ? @"chevron.up" : @"chevron.down")];
        if (toggleImage) [self.closeButton setImage:toggleImage forState:UIControlStateNormal];
        else [self.closeButton setTitle:(self.isExpanded ? @"⌃" : @"⌄") forState:UIControlStateNormal];
        self.closeButton.accessibilityLabel = self.isExpanded ? @"收起卡片内容" : @"展开卡片内容";
        self.dismissButton.frame = CGRectMake(width - closeInset - basePad - dismiss,
                                              statusY - 1.5 * scale, dismiss, dismiss);
        self.dismissButton.layer.cornerRadius = 5.0 * scale;
        self.dismissButton.hidden = NO;

        if (!self.isExpanded) {
            CGFloat y = 21.0 * scale, art = 20.0 * scale;
            CGFloat contentInset = basePad + PGFrameInset(y, y + art, height, radius);
            self.artworkView.frame = CGRectMake(contentInset, y, art, art);
            self.artworkView.layer.cornerRadius = 5.0 * scale;
            self.artworkFallbackLabel.frame = self.artworkView.frame;
            CGFloat tx = CGRectGetMaxX(self.artworkView.frame) + 6.0 * scale;
            CGFloat titleWidth = MAX(0.0, width - tx - basePad - close - dismiss - 7.0 * scale);
            self.titleLabel.frame = CGRectMake(tx, y - 1.0 * scale, titleWidth, 13.0 * scale);
            self.artistLabel.frame = CGRectMake(tx, y + 10.0 * scale, titleWidth, 11.0 * scale);
            self.titleLabel.font = [self configuredFontWithSize:9.0 weight:UIFontWeightSemibold];
            self.artistLabel.font = [self configuredFontWithSize:8.0 weight:UIFontWeightRegular];
            self.titleLabel.adjustsFontSizeToFitWidth = YES;
            self.artistLabel.adjustsFontSizeToFitWidth = YES;
            self.titleLabel.minimumScaleFactor = 0.45;
            self.artistLabel.minimumScaleFactor = 0.45;
            self.titleLabel.text = self.compactTrackText.length ? self.compactTrackText : @"未播放";
            NSString *compactArtist = PGNowPlaying.sharedInstance.artist ?: @"";
            NSString *compactAlbum = PGNowPlaying.sharedInstance.album ?: @"";
            self.artistLabel.text = compactArtist.length ? (compactAlbum.length ? [NSString stringWithFormat:@"%@ · %@", compactArtist, compactAlbum] : compactArtist) : compactAlbum;
            self.artistLabel.hidden = self.artistLabel.text.length == 0;
            self.artworkView.hidden = NO;
            self.artworkFallbackLabel.hidden = (self.artworkView.image != nil);
            self.titleLabel.hidden = NO;
            self.artistLabel.hidden = NO;
            self.lyricsLabel.hidden = YES;
            self.progressSlider.hidden = YES;
            self.progressSlider.frame = CGRectZero;
            self.elapsedLabel.hidden = YES;
            self.durationLabel.hidden = YES;
            self.previousButton.hidden = YES;
            self.playPauseButton.hidden = YES;
            self.nextButton.hidden = YES;
            self.artworkFallbackLabel.font = [UIFont systemFontOfSize:MAX(8.0, art * 0.62) weight:UIFontWeightLight];
            [self bringSubviewToFront:self.closeButton];
            [self bringSubviewToFront:self.dismissButton];
            return;
        }

        CGFloat art = MIN(38.0 * scale, MAX(30.0, height - 44.0 * scale));
        CGFloat contentY = 29.0 * scale;
        CGFloat contentInset = basePad + PGFrameInset(contentY, contentY + art, height, radius);
        self.artworkView.frame = CGRectMake(contentInset, contentY, art, art);
        self.artworkView.layer.cornerRadius = 7.0 * scale;
        self.artworkFallbackLabel.frame = self.artworkView.frame;
        self.artworkFallbackLabel.font = [UIFont systemFontOfSize:MAX(8.0, art * 0.62) weight:UIFontWeightLight];
        CGFloat tx = CGRectGetMaxX(self.artworkView.frame) + 8.0 * scale;
        CGFloat controlsWidth = MIN(112.0 * scale, width * 0.30);
        CGFloat controlsX = width - basePad - controlsWidth;
        CGFloat textW = MAX(48.0, controlsX - tx - 8.0 * scale);
        self.titleLabel.frame = CGRectMake(tx, contentY - 1.0 * scale, textW, 16.0 * scale);
        self.artistLabel.frame = CGRectMake(tx, contentY + 15.0 * scale, textW, 14.0 * scale);
        self.lyricsLabel.frame = CGRectMake(tx, contentY + 28.0 * scale, textW, 14.0 * scale);
        self.titleLabel.font = [self configuredFontWithSize:12.0 weight:UIFontWeightSemibold];
        self.artistLabel.font = [self configuredFontWithSize:9.0 weight:UIFontWeightRegular];
        self.lyricsLabel.font = [self configuredFontWithSize:9.0 weight:UIFontWeightRegular];
        self.artworkView.hidden = NO;
        self.artworkFallbackLabel.hidden = (self.artworkView.image != nil);
        self.titleLabel.hidden = NO;
        self.artistLabel.hidden = NO;
        self.lyricsLabel.hidden = NO;

        CGFloat buttonSize = 28.0 * scale;
        CGFloat gap = 5.0 * scale;
        CGFloat buttonY = contentY + 5.0 * scale;
        CGFloat buttonStart = width - basePad - (buttonSize * 3.0 + gap * 2.0);
        self.previousButton.frame = CGRectMake(buttonStart, buttonY, buttonSize, buttonSize);
        self.playPauseButton.frame = CGRectMake(buttonStart + buttonSize + gap, buttonY, buttonSize, buttonSize);
        self.nextButton.frame = CGRectMake(buttonStart + (buttonSize + gap) * 2.0, buttonY, buttonSize, buttonSize);
        self.previousButton.hidden = NO;
        self.playPauseButton.hidden = NO;
        self.nextButton.hidden = NO;

        if (PGNowPlaying.sharedInstance.canSeek) {
            CGFloat sliderY = height - 21.0 * scale;
            CGFloat sliderH = 15.0 * scale;
            CGFloat sliderInset = PGFrameInset(sliderY, sliderY + sliderH, height, radius);
            CGFloat sliderX = contentInset;
            CGFloat sliderW = MAX(40.0, width - sliderX - sliderInset);
            self.progressSlider.frame = CGRectMake(sliderX, sliderY, sliderW, sliderH);
            self.elapsedLabel.frame = CGRectMake(sliderX, sliderY + 12.0 * scale, 42.0 * scale, 12.0 * scale);
            self.durationLabel.frame = CGRectMake(sliderX, sliderY + 12.0 * scale, sliderW, 12.0 * scale);
            self.elapsedLabel.font = [self configuredFontWithSize:8.0 weight:UIFontWeightRegular];
            self.durationLabel.font = [self configuredFontWithSize:8.0 weight:UIFontWeightRegular];
            self.elapsedLabel.hidden = NO;
            self.durationLabel.hidden = NO;
            self.progressSlider.hidden = NO;
        } else {
            self.progressSlider.frame = CGRectZero;
            self.progressSlider.hidden = YES;
            self.elapsedLabel.hidden = YES;
            self.durationLabel.hidden = YES;
        }
        [self bringSubviewToFront:self.closeButton];
        [self bringSubviewToFront:self.dismissButton];
        return;
    }

    CGFloat pad = 12.0 * scale;
    CGFloat top = 7.0 * scale;
    CGFloat statusHeight = 27.0 * scale;
    CGFloat closeSize = 25.0 * scale;
    CGFloat radius = [self pgEffectiveCornerRadius];
    // Reserve independent space for the chevron and unmistakable × dismiss button.
    CGFloat sidePad = pad + PGFrameInset(top, top + statusHeight, height, radius);
    self.dismissButton.hidden = NO;
    CGFloat dismissSize = MIN(34.0 * scale, MAX(26.0, height - top - 4.0 * scale));
    self.dismissButton.frame = CGRectMake(MAX(sidePad, width - sidePad - dismissSize), top,
                                          dismissSize, dismissSize);
    self.dismissButton.layer.cornerRadius = dismissSize * 0.30;
    self.dismissButton.hidden = NO;
    CGFloat chevronRight = CGRectGetMinX(self.dismissButton.frame) - 4.0 * scale;
    self.closeButton.frame = CGRectMake(MAX(sidePad, chevronRight - closeSize), top, closeSize, closeSize);
    self.closeButton.hidden = NO;
    CGFloat rightEdge = CGRectGetMinX(self.closeButton.frame) - 5.0 * scale;
    CGFloat statusWidth = MAX(0.0, rightEdge - sidePad);

    // Give every status item a useful minimum before shrinking on compact screens.
    CGFloat timeWidth = MIN(68.0 * scale, statusWidth * 0.21);
    CGFloat batteryWidth = MIN(90.0 * scale, statusWidth * 0.24);
    CGFloat temperatureWidth = MIN(78.0 * scale, statusWidth * 0.22);
    CGFloat cpuWidth = MAX(0.0, statusWidth - timeWidth - batteryWidth - temperatureWidth);
    self.timeLabel.frame = CGRectMake(sidePad, top, timeWidth, statusHeight);
    CGFloat cursor = sidePad + timeWidth;
    self.batteryLabel.frame = CGRectMake(cursor, top, batteryWidth, statusHeight);
    cursor += batteryWidth;
    self.temperatureLabel.frame = CGRectMake(cursor, top, temperatureWidth, statusHeight);
    cursor += temperatureWidth;
    self.cpuLabel.frame = CGRectMake(cursor, top, cpuWidth, statusHeight);

    if (self.isExpanded) {
        CGFloat buttonSize = 38.0 * scale;
        CGFloat gap = 24.0 * scale;
        CGFloat controlsWidth = buttonSize * 3.0 + gap * 2.0;
        CGFloat controlsY = MAX(0.0, height - 47.0 * scale);
        CGFloat startX = MAX(pad, (width - controlsWidth) / 2.0);
        self.previousButton.frame = CGRectMake(startX, controlsY, buttonSize, buttonSize);
        self.playPauseButton.frame = CGRectMake(startX + buttonSize + gap, controlsY, buttonSize, buttonSize);
        self.nextButton.frame = CGRectMake(startX + (buttonSize + gap) * 2.0, controlsY, buttonSize, buttonSize);
    } else {
        self.previousButton.frame = CGRectZero;
        self.playPauseButton.frame = CGRectZero;
        self.nextButton.frame = CGRectZero;
    }

    CGFloat mediaTop = top + statusHeight + 5.0 * scale;
    CGFloat mediaBottom = self.isExpanded ? CGRectGetMinY(self.previousButton.frame) - 4.0 * scale : height - 8.0 * scale;
    CGFloat mediaHeight = MAX(0.0, mediaBottom - mediaTop);
    CGFloat artSize = MIN(60.0 * scale, MAX(36.0 * scale, mediaHeight - 2.0 * scale));
    CGFloat artY = mediaTop + MAX(0.0, (mediaHeight - artSize) / 2.0);
    self.artworkView.frame = CGRectMake(pad, artY, artSize, artSize);
    self.artworkView.layer.cornerRadius = 9.0 * scale;
    self.artworkFallbackLabel.frame = self.artworkView.frame;

    CGFloat textX = CGRectGetMaxX(self.artworkView.frame) + 10.0 * scale;
    CGFloat textWidth = MAX(0.0, width - pad - textX);
    CGFloat titleHeight = 19.0 * scale;
    CGFloat artistHeight = 16.0 * scale;
    CGFloat lyricsHeight = 15.0 * scale;
    CGFloat textBlockHeight = titleHeight + artistHeight + lyricsHeight;
    CGFloat textY = mediaTop + MAX(0.0, (mediaHeight - textBlockHeight) / 2.0);
    self.titleLabel.frame = CGRectMake(textX, textY, textWidth, titleHeight);
    self.artistLabel.frame = CGRectMake(textX, textY + titleHeight, textWidth, artistHeight);
    self.lyricsLabel.frame = CGRectMake(textX, textY + titleHeight + artistHeight, textWidth, lyricsHeight);
    if(self.compactMode&&self.isExpanded&&PGNowPlaying.sharedInstance.canSeek){
        CGFloat sx=textX,sy=height-19.0*scale;
        CGFloat sliderInset=PGFrameInset(sy,sy+15.0*scale,height,radius);
        self.progressSlider.frame=CGRectMake(sx,sy,MAX(40.0,width-sx-sliderInset),15.0*scale);
        self.progressSlider.hidden=NO;
    }else{self.progressSlider.frame=CGRectZero;self.progressSlider.hidden=YES;}

    BOOL controlsVisible = self.isExpanded;
    self.previousButton.hidden = !controlsVisible;
    self.playPauseButton.hidden = !controlsVisible;
    self.nextButton.hidden = !controlsVisible;
    self.titleLabel.hidden = NO;
    self.artistLabel.hidden = NO;
    self.lyricsLabel.hidden = NO;
    [self bringSubviewToFront:self.closeButton];
    [self bringSubviewToFront:self.dismissButton];
}

#pragma mark - Content updates

static NSString *PGFirstLyricLine(NSString *lyrics) {
    for (NSString *line in [lyrics componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *candidate = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!candidate.length || [candidate hasPrefix:@"[ar:"] || [candidate hasPrefix:@"[ti:"] || [candidate hasPrefix:@"[al:"]) continue;
        NSRegularExpression *prefix = [NSRegularExpression regularExpressionWithPattern:@"^(?:\\[\\d{1,2}:\\d{2}(?:\\.\\d{1,3})?\\])+\\s*" options:0 error:nil];
        candidate = [prefix stringByReplacingMatchesInString:candidate options:0 range:NSMakeRange(0, candidate.length) withTemplate:@""];
        if (candidate.length) return candidate;
    }
    return nil;
}

static NSString *PGTimedLyricAtTime(NSString *lrc, double seconds) {
    if (lrc.length == 0) return nil;
    NSArray<NSString *> *lines = [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    double bestTime = -1.0;
    NSString *bestText = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\]" options:0 error:nil];
    for (NSString *line in lines) {
        NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!matches.count) continue;
        NSTextCheckingResult *last = matches.lastObject;
        NSString *text = [line substringFromIndex:NSMaxRange([last range])];
        for (NSTextCheckingResult *match in matches) {
            double mm = [[line substringWithRange:[match rangeAtIndex:1]] doubleValue];
            double ss = [[line substringWithRange:[match rangeAtIndex:2]] doubleValue];
            double t = mm * 60.0 + ss;
            if ([match rangeAtIndex:3].location != NSNotFound) {
                NSString *fraction = [line substringWithRange:[match rangeAtIndex:3]];
                t += fraction.doubleValue / pow(10.0, fraction.length);
            }
            if (t <= seconds && t >= bestTime) { bestTime = t; bestText = text; }
        }
    }
    return bestText.length ? bestText : nil;
}

- (void)fetchLyricsForTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album duration:(double)duration {
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", title ?: @"", artist ?: @"", album ?: @""];
    if (key.length < 3 || [key isEqualToString:self.currentLyricKey]) return;
    [self.lyricsTask cancel];
    self.lyricsTask = nil;
    NSUInteger generation = ++self.lyricsRequestGeneration;
    self.currentLyricKey = key;
    if (self.lyricsCache[key]) { self.currentLyrics = self.lyricsCache[key]; return; }
    self.currentLyrics = @"正在查找歌词…";
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://lrclib.net/api/search"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:[NSString stringWithFormat:@"%@ %@", title ?: @"", artist ?: @""]]];
    NSURL *url = components.URL;
    if (!url) { self.currentLyrics = @"暂无歌词"; return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:8.0];
    [request setValue:@"Ntonia-PreferenceLoader/1.1 (iOS lyrics lookup)" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    self.lyricsTask = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        BOOL validResponse = !error && data.length > 0 && (!http || (http.statusCode >= 200 && http.statusCode < 300));
        NSArray *rows = validResponse ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *best = nil;
        double bestScore = -DBL_MAX;
        if ([rows isKindOfClass:NSArray.class]) for (NSDictionary *row in rows) {
            NSString *plain = [row[@"plainLyrics"] isKindOfClass:NSString.class] ? row[@"plainLyrics"] : nil;
            NSString *synced = [row[@"syncedLyrics"] isKindOfClass:NSString.class] ? row[@"syncedLyrics"] : nil;
            if (!plain.length && !synced.length) continue;
            double candidateDuration = [row[@"duration"] respondsToSelector:@selector(doubleValue)] ? [row[@"duration"] doubleValue] : 0.0;
            double score = 0.0;
            if (duration > 0.0 && candidateDuration > 0.0) score -= fabs(candidateDuration - duration) * 0.25;
            NSString *rowArtist = [row[@"artistName"] description] ?: @"";
            if (artist.length && [rowArtist localizedCaseInsensitiveContainsString:artist]) score += 20.0;
            NSString *rowTitle = [row[@"trackName"] description] ?: @"";
            if (title.length && ![rowTitle localizedCaseInsensitiveContainsString:title]) continue;
            if (title.length) score += 30.0;
            if (synced.length) score += 2.0;
            if (score > bestScore) { bestScore = score; best = row; }
        }
        NSString *lyric = [best[@"syncedLyrics"] isKindOfClass:NSString.class] ? best[@"syncedLyrics"] : nil;
        if (!lyric.length) lyric = [best[@"plainLyrics"] isKindOfClass:NSString.class] ? best[@"plainLyrics"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            PGGrabberOverlayView *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.lyricsLookupEnabled ||
                strongSelf.lyricsRequestGeneration != generation || ![strongSelf.currentLyricKey isEqualToString:key]) return;
            strongSelf.lyricsTask = nil;
            if (!validResponse) {
                strongSelf.currentLyrics = @"歌词查询失败";
                [strongSelf setNeedsLayout];
                return; // transient network/HTTP errors must not poison the cache
            }
            strongSelf.currentLyrics = lyric.length ? lyric : @"暂无歌词";
            if (lyric.length) strongSelf.lyricsCache[key] = lyric;
            if (strongSelf.lyricsCache.count > 40) [strongSelf.lyricsCache removeObjectForKey:strongSelf.lyricsCache.allKeys.firstObject];
            [strongSelf updateContents];
        });
    }];
    [self.lyricsTask resume];
}

- (NSString *)formattedTime:(double)seconds {
    if (!isfinite(seconds) || seconds < 0.0) seconds = 0.0;
    NSInteger total = (NSInteger)floor(seconds);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

- (NSInteger)currentBatteryPercentage {
    Class cls = NSClassFromString(@"SBUIController");
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [cls sharedInstance];
        if ([controller respondsToSelector:@selector(batteryCapacityAsPercentage)]) {
            NSInteger percent = [controller batteryCapacityAsPercentage];
            if (percent >= 0 && percent <= 100) return percent;
        }
    }
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    float level = UIDevice.currentDevice.batteryLevel;
    return level < 0.0 ? 0 : (NSInteger)lroundf(level * 100.0f);
}

- (BOOL)isCharging {
    Class cls = NSClassFromString(@"SBUIController");
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [cls sharedInstance];
        if ([controller respondsToSelector:@selector(isOnAC)]) return [controller isOnAC];
    }
    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

- (void)updateContents {
    PGNowPlaying *nowPlaying = PGNowPlaying.sharedInstance;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.dateFormat = PerfectGrabberPreferences.sharedPreferences.disable24Hour ? @"h:mm a" : @"HH:mm";
    self.timeLabel.text = [formatter stringFromDate:NSDate.date] ?: @"--:--";

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    self.vibrationFeedbackEnabled = preferences.vibrationFeedback;
    NSString *batteryIcon = (preferences.chargingIcon && [self isCharging]) ? @"⚡" : @"▰";
    self.batteryLabel.text = [NSString stringWithFormat:@"%@ %ld%%", batteryIcon, (long)[self currentBatteryPercentage]];

    double temperature = PGBatteryTemperatureCelsius();
    self.temperatureLabel.text = isfinite(temperature) ? [NSString stringWithFormat:@"T %.0f°", temperature] : @"T —";
    double cpu = PGCPUUsagePercent();
    self.cpuLabel.text = isfinite(cpu) ? [NSString stringWithFormat:@"CPU %.0f%%", cpu] : @"CPU —";

    NSString *title = nowPlaying.title;
    NSString *artist = nowPlaying.artist;
    NSString *album = nowPlaying.album;
    if (self.lyricsLookupEnabled && preferences.lyricsLookupEnabled && title.length) {
        self.lyricsLookupEnabled = preferences.lyricsLookupEnabled;
        [self fetchLyricsForTitle:title artist:artist album:album duration:nowPlaying.duration];
    } else {
        self.lyricsLookupEnabled = preferences.lyricsLookupEnabled;
        self.lyricsRequestGeneration += 1;
        [self.lyricsTask cancel];
        self.lyricsTask = nil;
        self.currentLyricKey = nil;
        self.currentLyrics = @"暂无歌词";
    }
    NSData *artworkData = nowPlaying.artworkData;
    // Save the last valid track so the idle card still has artwork/metadata after playback stops.
    if (artworkData.length && ![artworkData isEqualToData:self.displayedArtworkData]) {
        self.displayedArtworkData = [artworkData copy];
        self.artworkView.image = [UIImage imageWithData:artworkData];
    }
    BOOL remotePlaying = nowPlaying.isPlaying;
    BOOL showPlaying = remotePlaying;
    if (self.hasPendingPlaybackState) {
        if (remotePlaying == self.pendingPlaybackState || [self.pendingPlaybackDeadline timeIntervalSinceNow] <= 0.0) {
            self.hasPendingPlaybackState = NO;
        } else {
            showPlaying = self.pendingPlaybackState;
        }
    }
    self.titleLabel.text = title.length ? title : (showPlaying ? @"正在播放" : @"未播放");
    self.artistLabel.text = artist.length ? ([album length] ? [NSString stringWithFormat:@"%@ · %@", artist, album] : artist) : ([album length] ? album : @"—");
    NSString *lyric = (nowPlaying.duration > 0.0) ? PGTimedLyricAtTime(self.currentLyrics, nowPlaying.elapsed) : nil;
    if (!lyric.length && self.currentLyrics.length && ![self.currentLyrics isEqualToString:@"暂无歌词"] && ![self.currentLyrics isEqualToString:@"正在查找歌词…"]) lyric = PGFirstLyricLine(self.currentLyrics);
    self.lyricsLabel.text = lyric.length ? lyric : (self.currentLyrics.length ? self.currentLyrics : @"暂无歌词");
    self.elapsedLabel.text = [self formattedTime:self.isSeeking ? self.displayedSeekElapsed : nowPlaying.elapsed];
    self.durationLabel.text = [self formattedTime:nowPlaying.duration];
    self.compactStatusText = [NSString stringWithFormat:@"%@ %@ ♨%.0f° CPU%.0f%%", self.timeLabel.text ?: @"--:--", self.batteryLabel.text ?: @"—", isfinite(temperature)?temperature:0.0, isfinite(cpu)?cpu:0.0];
    self.compactTrackText = title.length ? title : (showPlaying ? @"正在播放" : @"未播放");
    if(!self.isSeeking&&nowPlaying.duration>0)self.progressSlider.value=(float)MIN(1.0,MAX(0.0,nowPlaying.elapsed/nowPlaying.duration));
    self.artworkFallbackLabel.hidden = (self.artworkView.image != nil);

    if (showPlaying) {
        UIImage *pause = [UIImage systemImageNamed:@"pause.fill"];
        if (pause) [self.playPauseButton setImage:pause forState:UIControlStateNormal];
        else [self.playPauseButton setTitle:@"Ⅱ" forState:UIControlStateNormal];
    } else {
        UIImage *play = [UIImage systemImageNamed:@"play.fill"];
        if (play) [self.playPauseButton setImage:play forState:UIControlStateNormal];
        else [self.playPauseButton setTitle:@"▶︎" forState:UIControlStateNormal];
    }
    [self setNeedsLayout];
}

#pragma mark - Gestures and controls

- (void)progressBegan:(UISlider *)slider {
    PGNowPlaying *nowPlaying = PGNowPlaying.sharedInstance;
    if (nowPlaying.duration <= 0.0) { self.isSeeking = NO; return; }
    self.isSeeking = YES;
    // 把 0–1 切成固定 30 格：每跨一格给一次 selection 触感，就是"一格格"的手感。
    self.seekDetentCount = 30;
    self.lastHapticStep = (NSInteger)floor(slider.value * (CGFloat)self.seekDetentCount + 0.5);
    self.displayedSeekElapsed = slider.value * nowPlaying.duration;
    [self.seekHaptics prepare];
}
- (void)progressChanged:(UISlider *)slider {
    double duration = PGNowPlaying.sharedInstance.duration;
    if (!self.isSeeking || duration <= 0.0) return;
    NSInteger detents = MAX(1, self.seekDetentCount);
    NSInteger step = (NSInteger)floor(slider.value * (CGFloat)detents + 0.5);
    if (self.vibrationFeedbackEnabled && step != self.lastHapticStep) {
        // 拖动过程中就逐格触发，不等松手。
        [self.seekHaptics selectionChanged];
        [self.seekHaptics prepare];
    }
    self.lastHapticStep = step;
    self.displayedSeekElapsed = slider.value * duration;
}
- (void)progressEnded:(UISlider *)slider {
    double duration = PGNowPlaying.sharedInstance.duration;
    if (self.isSeeking && duration > 0.0) {
        self.displayedSeekElapsed = slider.value * duration;
        [PGNowPlaying.sharedInstance seekToElapsedTime:self.displayedSeekElapsed];
    }
    self.isSeeking = NO;
}

- (void)handleCardLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (!self.longPressControls) return;
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        if (self.vibrationFeedbackEnabled) {
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [generator prepare];
            [generator impactOccurred];
        }
        if (!self.isExpanded) [self setExpanded:YES animated:YES];
        if (self.onLongPressStateChange) self.onLongPressStateChange(YES);
    } else if (recognizer.state == UIGestureRecognizerStateEnded || recognizer.state == UIGestureRecognizerStateCancelled || recognizer.state == UIGestureRecognizerStateFailed) {
        // Keep the expanded card visible after the user's long press ends.
        // The arrow button is the explicit collapse control.
        if (self.onLongPressStateChange) self.onLongPressStateChange(NO);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *v=touch.view;
    while(v&&v!=self){if([v isKindOfClass:UIControl.class])return NO;v=v.superview;}
    return YES;
}

- (void)closeTapped {
    [self stopUpdating];
    if (self.onClose) self.onClose();
    else [self removeFromSuperview];
}

- (void)toggleExpandedTapped {
    [self tapHaptic];
    [self setExpanded:!self.isExpanded animated:YES];
}

- (void)tapHaptic {
    if (!PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) return;
    UIImpactFeedbackGenerator *g=[[UIImpactFeedbackGenerator alloc]initWithStyle:UIImpactFeedbackStyleLight];[g prepare];[g impactOccurred];
}
- (void)previousTapped { [self tapHaptic]; [PGNowPlaying.sharedInstance sendCommand:PGMediaCommandPrevious]; }

- (void)playPauseTapped {
    [self tapHaptic];
    BOOL currentlyPlaying = self.hasPendingPlaybackState ? self.pendingPlaybackState : PGNowPlaying.sharedInstance.isPlaying;
    self.pendingPlaybackState = !currentlyPlaying;
    self.hasPendingPlaybackState = YES;
    self.pendingPlaybackDeadline = [NSDate dateWithTimeIntervalSinceNow:2.5];
    UIImage *image = [UIImage systemImageNamed:self.pendingPlaybackState ? @"pause.fill" : @"play.fill"];
    if (image) [self.playPauseButton setImage:image forState:UIControlStateNormal];
    else [self.playPauseButton setTitle:(self.pendingPlaybackState ? @"Ⅱ" : @"▶︎") forState:UIControlStateNormal];
    self.titleLabel.text = self.pendingPlaybackState ? @"正在播放" : @"已暂停";
    [self setNeedsLayout];
    [PGNowPlaying.sharedInstance sendCommand:self.pendingPlaybackState ? PGMediaCommandPlay : PGMediaCommandPause];
}

- (void)nextTapped { [self tapHaptic]; [PGNowPlaying.sharedInstance sendCommand:PGMediaCommandNext]; }

#pragma mark - Monitoring

- (void)startUpdating {
    [self stopUpdating];
    [PGNowPlaying.sharedInstance startMonitoring];
    [self refreshAppearance];
    [self updateContents];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateContents) userInfo:nil repeats:YES];
}

- (void)stopUpdating {
    [self.timer invalidate];
    self.timer = nil;
    self.lyricsRequestGeneration += 1;
    [self.lyricsTask cancel];
    self.lyricsTask = nil;
    [PGNowPlaying.sharedInstance stopMonitoring];
}

@end
