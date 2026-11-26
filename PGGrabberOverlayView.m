#import "PGGrabberOverlayView.h"
#import "PGHardwareMetrics.h"
#import "PGNowPlaying.h"
#import "PerfectGrabberPreferences.h"
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (NSInteger)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
@end

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
@property (nonatomic, strong) UIButton *closeButton;
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
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) BOOL hasPendingPlaybackState;
@property (nonatomic, assign) BOOL pendingPlaybackState;
@property (nonatomic, strong) NSDate *pendingPlaybackDeadline;
@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, assign) BOOL isSeeking;
@property (nonatomic, assign) double displayedSeekElapsed;
@property (nonatomic, assign) NSInteger lastHapticStep;
@property (nonatomic, assign) BOOL vibrationFeedbackEnabled;
@property (nonatomic, copy) NSString *compactStatusText;
@property (nonatomic, copy) NSString *compactTrackText;
- (UILabel *)newLabelWithWeight:(UIFontWeight)weight alignment:(NSTextAlignment)alignment;
- (UIButton *)buttonWithSymbol:(NSString *)symbol fallback:(NSString *)fallback accessibility:(NSString *)accessibility;
- (void)updateContents;
@end

@implementation PGGrabberOverlayView

@synthesize cardScale = _cardScale;
@synthesize blurAmount = _blurAmount;
@synthesize backgroundOpacity = _backgroundOpacity;
@synthesize cornerRadius = _cornerRadius;
@synthesize expanded = _expanded;
@synthesize compactMode = _compactMode;
@synthesize deferNativeGrabberDismissal = _deferNativeGrabberDismissal;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    _cardScale = PGClamp(preferences.cardScale, 0.65, 1.50);
    _blurAmount = PGClamp(preferences.cardBlur, 0.0, 1.0);
    _backgroundOpacity = PGClamp(preferences.cardOpacity, 0.0, 1.0);
    _cornerRadius = PGClamp(preferences.cardCornerRadius, 0.0, 80.0);

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

    _timeLabel = [self newLabelWithWeight:UIFontWeightSemibold alignment:NSTextAlignmentCenter];
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
    _closeButton.layer.cornerRadius = 13.0;
    _closeButton.tintColor = UIColor.whiteColor;
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeButton];

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
    _cardLongPress.minimumPressDuration = 0.40;
    _cardLongPress.allowableMovement = 18.0;
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
    button.layer.cornerRadius = 18.0;
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
    CGFloat next = PGClamp(value, 0.65, 1.50);
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

- (CGFloat)cornerRadius { return _cornerRadius; }
- (void)setCornerRadius:(CGFloat)value {
    _cornerRadius = PGClamp(value, 0.0, 80.0);
    [self refreshAppearance];
    [self setNeedsLayout];
}

- (BOOL)isExpanded { return _expanded; }
- (BOOL)isCompactMode { return _compactMode; }
- (void)setCompactMode:(BOOL)value { _compactMode=value; [self setNeedsLayout]; }
- (BOOL)deferNativeGrabberDismissal { return _deferNativeGrabberDismissal; }
- (void)setDeferNativeGrabberDismissal:(BOOL)value { _deferNativeGrabberDismissal=value; }

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) return;
    _expanded = expanded;
    CGFloat targetHeight = [self heightForCurrentWidth];

    void (^layoutBlock)(void) = ^{
        if (CGRectGetWidth(self.bounds) > 0.0 && CGRectGetHeight(self.bounds) > 0.0) {
            CGRect frame = self.frame;
            frame.size.height = targetHeight;
            self.frame = frame;
        }
        [self setNeedsLayout];
        [self layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut animations:layoutBlock completion:^(BOOL finished) {
            if (self.onHeightChange) self.onHeightChange(targetHeight);
        }];
    } else {
        layoutBlock();
        if (self.onHeightChange) self.onHeightChange(targetHeight);
    }
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat scale = PGClamp(self.cardScale, 0.65, 1.50);
    if (self.compactMode) return (self.isExpanded ? 104.0 : 44.0) * scale;
    // Room for a readable status row, a 60pt artwork row, and expanded control buttons.
    return (112.0 + (self.isExpanded ? 64.0 : 0.0)) * scale;
}

- (CGFloat)heightForCurrentWidth {
    return [self heightForWidth:CGRectGetWidth(self.bounds)];
}

#pragma mark - Appearance and layout

- (UIFont *)configuredFontWithSize:(CGFloat)size weight:(UIFontWeight)weight {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    CGFloat requested = (preferences.fontSize > 0.0 ? preferences.fontSize : 13.0) * self.cardScale;
    return [UIFont systemFontOfSize:MAX(9.0, MIN(24.0, requested)) weight:weight];
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
    self.layer.cornerRadius = MIN(MIN(CGRectGetWidth(self.bounds),CGRectGetHeight(self.bounds))*0.5,MAX(0.0,self.cornerRadius*self.cardScale));
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.blurView.layer.cornerRadius = self.layer.cornerRadius;
    self.blurView.clipsToBounds = YES;
    self.blurView.layer.masksToBounds = YES;
    self.gaussianBlurBackdrop.layer.cornerRadius = self.layer.cornerRadius;
    self.gaussianBlurBackdrop.clipsToBounds = YES;
    self.gaussianBlurBackdrop.layer.masksToBounds = YES;
    self.tintView.layer.cornerRadius = self.layer.cornerRadius;
    self.tintView.clipsToBounds = YES;
    self.tintView.layer.masksToBounds = YES;
    self.timeLabel.textColor = textColor;
    self.batteryLabel.textColor = textColor;
    self.temperatureLabel.textColor = textColor;
    self.cpuLabel.textColor = textColor;
    self.titleLabel.textColor = textColor;
    self.artistLabel.textColor = [textColor colorWithAlphaComponent:0.88];
    self.lyricsLabel.textColor = [textColor colorWithAlphaComponent:0.64];
    self.artworkFallbackLabel.textColor = textColor;
    self.closeButton.tintColor = textColor;

    self.timeLabel.font = [self configuredFontWithSize:14.0 weight:UIFontWeightSemibold];
    for (UILabel *label in @[_batteryLabel, _temperatureLabel, _cpuLabel]) {
        label.font = [self configuredFontWithSize:11.0 weight:UIFontWeightMedium];
    }
    self.titleLabel.font = [self configuredFontWithSize:15.0 weight:UIFontWeightSemibold];
    self.artistLabel.font = [self configuredFontWithSize:12.0 weight:UIFontWeightRegular];
    self.lyricsLabel.font = [self configuredFontWithSize:11.0 weight:UIFontWeightRegular];
    self.artworkFallbackLabel.font = [UIFont systemFontOfSize:25.0 * self.cardScale weight:UIFontWeightLight];
    self.closeButton.layer.cornerRadius = 13.0 * self.cardScale;
    for (UIButton *button in @[_previousButton, _playPauseButton, _nextButton]) {
        button.tintColor = textColor;
        button.layer.cornerRadius = 19.0 * self.cardScale;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat scale = PGClamp(self.cardScale, 0.65, 1.50);
    self.layer.cornerRadius = MIN(MIN(width,height)*0.5,MAX(0.0,self.cornerRadius*scale));
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.blurView.frame = self.bounds; self.blurView.layer.cornerRadius=self.layer.cornerRadius;
    self.gaussianBlurBackdrop.frame = self.bounds; self.gaussianBlurBackdrop.layer.cornerRadius=self.layer.cornerRadius;
    self.tintView.frame = self.bounds; self.tintView.layer.cornerRadius=self.layer.cornerRadius;

    if (self.compactMode) {
        CGFloat pad=8.0*scale, close=20.0*scale, row=17.0*scale;
        CGFloat statusWidth=MAX(0.0,width-pad*2.0-close-3.0*scale);
        if (!self.isExpanded) {
            CGFloat rowWidth=statusWidth, rowX=(width-rowWidth)*0.5, tw=rowWidth*0.20,bw=rowWidth*0.23,hw=rowWidth*0.22;
            self.timeLabel.frame=CGRectMake(rowX,0,tw,row);
            self.batteryLabel.frame=CGRectMake(rowX+tw,0,bw,row);
            self.temperatureLabel.frame=CGRectMake(rowX+tw+bw,0,hw,row);
            self.cpuLabel.frame=CGRectMake(rowX+tw+bw+hw,0,rowWidth-tw-bw-hw,row);
            self.closeButton.frame=CGRectMake(width-pad-close,0,close,close); self.closeButton.hidden=NO;
            for (UILabel *label in @[_timeLabel,_batteryLabel,_temperatureLabel,_cpuLabel]) { label.font=[self configuredFontWithSize:9.0 weight:UIFontWeightSemibold]; label.adjustsFontSizeToFitWidth=YES; label.minimumScaleFactor=0.35; label.textAlignment=NSTextAlignmentCenter; }
            CGFloat y=19.0*scale, art=18.0*scale;
            self.artworkView.frame=CGRectMake(pad,y,art,art); self.artworkView.layer.cornerRadius=4.0*scale; self.artworkFallbackLabel.frame=self.artworkView.frame;
            CGFloat tx=CGRectGetMaxX(self.artworkView.frame)+5.0*scale;
            self.titleLabel.frame=CGRectMake(tx,y,MAX(0.0,width-pad-tx),art);
            self.titleLabel.font=[self configuredFontWithSize:9.0 weight:UIFontWeightSemibold]; self.titleLabel.adjustsFontSizeToFitWidth=YES; self.titleLabel.minimumScaleFactor=0.5; self.titleLabel.text=self.compactTrackText.length?self.compactTrackText:self.titleLabel.text;
            self.artistLabel.frame=CGRectZero; self.lyricsLabel.frame=CGRectZero;
            self.artworkView.hidden=NO; self.artworkFallbackLabel.hidden=(self.artworkView.image!=nil); self.titleLabel.hidden=NO; self.artistLabel.hidden=YES; self.lyricsLabel.hidden=YES;
            self.progressSlider.hidden=YES; self.progressSlider.frame=CGRectZero;
            self.previousButton.hidden=YES; self.playPauseButton.hidden=YES; self.nextButton.hidden=YES;
            return;
        }
        CGFloat rowWidth=statusWidth, rowX=(width-rowWidth)*0.5, tw=rowWidth*0.20,bw=rowWidth*0.23,hw=rowWidth*0.22;
        self.timeLabel.frame=CGRectMake(rowX,2.0*scale,tw,row);
        self.batteryLabel.frame=CGRectMake(rowX+tw,2.0*scale,bw,row);
        self.temperatureLabel.frame=CGRectMake(rowX+tw+bw,2.0*scale,hw,row);
        self.cpuLabel.frame=CGRectMake(rowX+tw+bw+hw,2.0*scale,rowWidth-tw-bw-hw,row);
        self.closeButton.frame=CGRectMake(width-pad-close,2.0*scale,close,close); self.closeButton.hidden=NO;
        for(UILabel*label in @[_timeLabel,_batteryLabel,_temperatureLabel,_cpuLabel]){label.font=[self configuredFontWithSize:9.0 weight:UIFontWeightSemibold];label.adjustsFontSizeToFitWidth=YES;label.minimumScaleFactor=0.35;label.textAlignment=NSTextAlignmentCenter;}
        CGFloat y=24.0*scale,art=34.0*scale;self.artworkView.frame=CGRectMake(pad,y,art,art);self.artworkView.layer.cornerRadius=6.0*scale;self.artworkFallbackLabel.frame=self.artworkView.frame;
        CGFloat tx=CGRectGetMaxX(self.artworkView.frame)+7.0*scale,controls=88.0*scale,textW=MAX(20.0,width-pad-tx-controls-4.0*scale);
        self.titleLabel.frame=CGRectMake(tx,y,textW,18.0*scale);self.artistLabel.frame=CGRectMake(tx,y+18.0*scale,textW,15.0*scale);self.lyricsLabel.frame=CGRectZero;
        self.artworkView.hidden=NO;self.artworkFallbackLabel.hidden=(self.artworkView.image!=nil);self.titleLabel.hidden=NO;self.artistLabel.hidden=NO;self.lyricsLabel.hidden=YES;
        CGFloat bs=24.0*scale,gap=4.0*scale,x=width-pad-(bs*3.0+gap*2.0),cy=y+4.0*scale;
        self.previousButton.frame=CGRectMake(x,cy,bs,bs);self.playPauseButton.frame=CGRectMake(x+bs+gap,cy,bs,bs);self.nextButton.frame=CGRectMake(x+(bs+gap)*2.0,cy,bs,bs);
        self.previousButton.hidden=NO;self.playPauseButton.hidden=NO;self.nextButton.hidden=NO;
        if(PGNowPlaying.sharedInstance.canSeek){self.progressSlider.frame=CGRectMake(tx,height-18.0*scale,width-tx-pad,14.0*scale);self.progressSlider.hidden=NO;}else{self.progressSlider.frame=CGRectZero;self.progressSlider.hidden=YES;}
        return;
    }

    CGFloat pad = 12.0 * scale;
    CGFloat top = 7.0 * scale;
    CGFloat statusHeight = 27.0 * scale;
    CGFloat closeSize = 25.0 * scale;
    self.closeButton.frame = CGRectMake(MAX(pad, width - pad - closeSize), top, closeSize, closeSize);
    CGFloat rightEdge = CGRectGetMinX(self.closeButton.frame) - 5.0 * scale;
    CGFloat statusWidth = MAX(0.0, rightEdge - pad);

    // Give every status item a useful minimum before shrinking on compact screens.
    CGFloat timeWidth = MIN(68.0 * scale, statusWidth * 0.21);
    CGFloat batteryWidth = MIN(90.0 * scale, statusWidth * 0.24);
    CGFloat temperatureWidth = MIN(78.0 * scale, statusWidth * 0.22);
    CGFloat cpuWidth = MAX(0.0, statusWidth - timeWidth - batteryWidth - temperatureWidth);
    self.timeLabel.frame = CGRectMake(pad, top, timeWidth, statusHeight);
    CGFloat cursor = pad + timeWidth;
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
    if(self.compactMode&&self.isExpanded&&PGNowPlaying.sharedInstance.canSeek){CGFloat sx=textX,sy=height-19.0*scale;self.progressSlider.frame=CGRectMake(sx,sy,MAX(40.0,width-sx-pad),15.0*scale);self.progressSlider.hidden=NO;}else{self.progressSlider.frame=CGRectZero;self.progressSlider.hidden=YES;}

    BOOL controlsVisible = self.isExpanded;
    self.previousButton.hidden = !controlsVisible;
    self.playPauseButton.hidden = !controlsVisible;
    self.nextButton.hidden = !controlsVisible;
    self.titleLabel.hidden = NO;
    self.artistLabel.hidden = NO;
    self.lyricsLabel.hidden = NO;
}

#pragma mark - Content updates

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
    self.temperatureLabel.text = isfinite(temperature) ? [NSString stringWithFormat:@"♨ %.0f°", temperature] : @"♨ —";
    double cpu = PGCPUUsagePercent();
    self.cpuLabel.text = isfinite(cpu) ? [NSString stringWithFormat:@"CPU %.0f%%", cpu] : @"CPU —";

    NSString *title = nowPlaying.title;
    NSString *artist = nowPlaying.artist;
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
    self.artistLabel.text = artist.length ? artist : @"—";
    self.lyricsLabel.text = @"暂无歌词";
    self.compactStatusText = [NSString stringWithFormat:@"%@ %@ ♨%.0f° CPU%.0f%%", self.timeLabel.text ?: @"--:--", self.batteryLabel.text ?: @"—", isfinite(temperature)?temperature:0.0, isfinite(cpu)?cpu:0.0];
    self.compactTrackText = title.length ? (artist.length ? [NSString stringWithFormat:@"%@ · %@",title,artist] : title) : (showPlaying?@"正在播放":@"未播放");
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
    self.lastHapticStep = (NSInteger)lrint(slider.value * 20.0);
    self.displayedSeekElapsed = slider.value * nowPlaying.duration;
}
- (void)progressChanged:(UISlider *)slider {
    double duration = PGNowPlaying.sharedInstance.duration;
    if (!self.isSeeking || duration <= 0.0) return;
    NSInteger step = (NSInteger)lrint(slider.value * 20.0);
    if (self.vibrationFeedbackEnabled && step != self.lastHapticStep) AudioServicesPlaySystemSound(1519);
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
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        if (self.onLongPressStateChange) self.onLongPressStateChange(YES);
        if (!self.isExpanded) [self setExpanded:YES animated:YES];
    } else if (recognizer.state == UIGestureRecognizerStateEnded || recognizer.state == UIGestureRecognizerStateCancelled || recognizer.state == UIGestureRecognizerStateFailed) {
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
    [PGNowPlaying.sharedInstance stopMonitoring];
}

@end
