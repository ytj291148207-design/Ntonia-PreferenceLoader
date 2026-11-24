#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import "PGHardwareMetrics.h"
#import "PGNowPlaying.h"
#import <math.h>
#import <QuartzCore/QuartzCore.h>

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (NSInteger)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
@end

/// 单排时左右内边距。
static const CGFloat PGSingleLinePadding = 10.0;
/// 单排时"时间电量"与音乐区之间的间距（中间夹一条分隔线）。
static const CGFloat PGSingleLineSectionGap = 7.0;
/// 音乐标题最多占多宽，超出就截断，避免歌名把胶囊拉得横贯整条屏幕。
static const CGFloat PGMusicMaxTextWidth = 280.0;

@interface PGGrabberOverlayView ()
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *batteryLabel;
/// 单排最左边的"CPU 频率 + 电池温度"，和中间的时间之间也夹一条分隔线。
@property (nonatomic, strong) UILabel *metricsLabel;
@property (nonatomic, strong) UIView *metricsDivider;
@property (nonatomic, strong) UILabel *musicLabel;
@property (nonatomic, strong) UIImageView *musicArtworkView;
@property (nonatomic, strong) UIImageView *musicStateView;
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong) UIVisualEffectView *glassBlurView;
@property (nonatomic, strong) UIView *glassTintView;
@property (nonatomic, strong) UIView *glassSheenView;
@property (nonatomic, strong) CAGradientLayer *glassTintGradient;
@property (nonatomic, strong) CAGradientLayer *glassSheenGradient;
@property (nonatomic, strong) UILongPressGestureRecognizer *musicLongPress;
@property (nonatomic, strong) NSTimer *timer;

@property (nonatomic, assign) BOOL musicVisible;
@property (nonatomic, copy) NSString *musicTitle;
@property (nonatomic, copy) NSString *musicArtist;
@property (nonatomic, copy) NSData *displayedArtworkData;
@property (nonatomic, assign) BOOL musicPlaying;
/// 上次上报给宿主的宽度，用来判断"内容宽度真的变了"。
@property (nonatomic, assign) CGFloat reportedWidth;
@property (nonatomic, assign) BOOL reportedMusicVisible;
/// 防止 "量宽度 → 通知宿主 → 宿主再量宽度" 无限递归。
@property (nonatomic, assign) BOOL reportingSize;
@end

@implementation PGGrabberOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // hitTest opts into touches only while the long-press action is installed.
        self.userInteractionEnabled = YES;
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 10.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.backgroundColor = UIColor.clearColor;
        self.layer.borderWidth = 1.2 / MAX(UIScreen.mainScreen.scale, 1.0);
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;

        // 与音乐播放控制面板一致的深色超薄毛玻璃底。
        UIBlurEffect *glassEffect = nil;
        if (@available(iOS 13.0, *)) glassEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        else glassEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        _glassBlurView = [[UIVisualEffectView alloc] initWithEffect:glassEffect];
        _glassBlurView.userInteractionEnabled = NO;
        _glassBlurView.alpha = 0.80;
        [self addSubview:_glassBlurView];

        _glassTintView = [UIView new];
        _glassTintView.userInteractionEnabled = NO;
        _glassTintGradient = [CAGradientLayer layer];
        _glassTintGradient.colors = @[(__bridge id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
                                      (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.03].CGColor,
                                      (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.12].CGColor];
        _glassTintGradient.locations = @[@0.0, @0.55, @1.0];
        _glassTintGradient.startPoint = CGPointMake(0.5, 0.0);
        _glassTintGradient.endPoint = CGPointMake(0.5, 1.0);
        [_glassTintView.layer addSublayer:_glassTintGradient];
        [self addSubview:_glassTintView];

        _glassSheenView = [UIView new];
        _glassSheenView.userInteractionEnabled = NO;
        _glassSheenGradient = [CAGradientLayer layer];
        _glassSheenGradient.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.20].CGColor,
                                       (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.04].CGColor,
                                       (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        _glassSheenGradient.locations = @[@0.0, @0.35, @1.0];
        _glassSheenGradient.startPoint = CGPointMake(0.0, 0.0);
        _glassSheenGradient.endPoint = CGPointMake(0.35, 0.55);
        [_glassSheenView.layer addSublayer:_glassSheenGradient];
        [self addSubview:_glassSheenView];

        _timeLabel = [UILabel new];
        _batteryLabel = [UILabel new];
        for (UILabel *label in @[_timeLabel, _batteryLabel]) {
            label.textAlignment = NSTextAlignmentCenter;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.65;
            label.numberOfLines = 1;
            [self addSubview:label];
        }

        // 左边那截硬件指标：CPU 频率 + 电池温度。
        _metricsLabel = [UILabel new];
        _metricsLabel.numberOfLines = 1;
        _metricsLabel.textAlignment = NSTextAlignmentLeft;
        _metricsLabel.adjustsFontSizeToFitWidth = YES;
        _metricsLabel.minimumScaleFactor = 0.7;
        _metricsLabel.hidden = YES;
        [self addSubview:_metricsLabel];

        _metricsDivider = [UIView new];
        _metricsDivider.hidden = YES;
        [self addSubview:_metricsDivider];

        // Music metadata row; playback controls appear only in the long-press panel.
        _divider = [UIView new];
        _divider.hidden = YES;
        [self addSubview:_divider];

        _musicLabel = [UILabel new];
        _musicLabel.numberOfLines = 1;
        _musicLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _musicLabel.textAlignment = NSTextAlignmentLeft;
        _musicLabel.hidden = YES;
        _musicLabel.userInteractionEnabled = YES;
        [self addSubview:_musicLabel];
        _musicLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleMusicLongPress:)];
        _musicLongPress.minimumPressDuration = 0.35;
        _musicLongPress.allowableMovement = 14.0;
        // Attach to the entire card, not just the metadata label. hitTest below
        // keeps the overlay pass-through whenever no long-press action is installed.
        _musicLongPress.cancelsTouchesInView = NO;
        [self addGestureRecognizer:_musicLongPress];

        _musicArtworkView = [UIImageView new];
        _musicArtworkView.contentMode = UIViewContentModeScaleAspectFill;
        _musicArtworkView.clipsToBounds = YES;
        _musicArtworkView.layer.cornerRadius = 5.0;
        _musicArtworkView.hidden = YES;
        [self addSubview:_musicArtworkView];

        _musicStateView = [UIImageView new];
        _musicStateView.contentMode = UIViewContentModeScaleAspectFit;
        _musicStateView.hidden = YES;
        [self addSubview:_musicStateView];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 仅在长按回调有效时整张下拉卡片参与命中；否则所有区域继续穿透。
    // 这样保留 SpringBoard 原手势，不会因为透明覆盖层拦截其它触摸。
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled ||
        !self.onMusicLongPress) return nil;
    if (!CGRectContainsPoint(self.bounds, point)) return nil;
    return self;
}


#pragma mark - 外观

- (UIFont *)configuredFont {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (preferences.fontStyle == 1) {
        return [UIFont systemFontOfSize:preferences.fontSize weight:UIFontWeightBold];
    }
    UIFont *font = [UIFont systemFontOfSize:preferences.fontSize weight:UIFontWeightRegular];
    if (preferences.fontStyle == 2) {
        UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
        if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:preferences.fontSize];
    }
    return font;
}

- (NSInteger)currentBatteryPercentage {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(batteryCapacityAsPercentage)]) {
            return MAX(0, MIN(100, [controller batteryCapacityAsPercentage]));
        }
    }

    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    CGFloat level = UIDevice.currentDevice.batteryLevel;
    return level < 0 ? 0 : (NSInteger)lround(level * 100.0);
}

- (BOOL)isCharging {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(isOnAC)]) return [controller isOnAC];
    }
    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

- (NSString *)timeText {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale currentLocale];
    formatter.dateFormat = preferences.disable24Hour ? @"h:mm a" : @"HH:mm";
    return [formatter stringFromDate:NSDate.date];
}

- (NSString *)batteryText {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSInteger battery = [self currentBatteryPercentage];
    NSString *chargingPrefix = preferences.chargingIcon && [self isCharging] ? @"\u26A1 " : @"";
    return [NSString stringWithFormat:@"%@%ld%%", chargingPrefix, (long)battery];
}

- (void)updateContents {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    PGNowPlaying *nowPlaying = PGNowPlaying.sharedInstance;
    NSData *artworkData = nowPlaying.artworkData;
    if ((artworkData != self.displayedArtworkData) && ![artworkData isEqualToData:self.displayedArtworkData]) {
        self.displayedArtworkData = [artworkData copy];
        self.musicArtworkView.image = artworkData.length ? [UIImage imageWithData:artworkData] : nil;
    }
    NSString *time = [self timeText];
    NSString *battery = [self batteryText];

    NSString *playingApp = nowPlaying.bundleIdentifier;
    NSString *frontApp = nowPlaying.frontmostBundleIdentifier;
    BOOL inBackground = playingApp.length == 0 || frontApp.length == 0 ||
                        ![playingApp isEqualToString:frontApp];
    BOOL hasMusicText = nowPlaying.title.length > 0 || nowPlaying.artist.length > 0;
    BOOL hasMusicMetadata = hasMusicText || artworkData.length > 0;
    // Keep one unified music row for available metadata; stopped playback shows a neutral placeholder.
    BOOL showMusic = preferences.landscapeMusic && (hasMusicMetadata || !nowPlaying.isPlaying);
    BOOL playingInBackground = nowPlaying.isPlaying && hasMusicText && inBackground;
    [self setMusicVisible:showMusic
                    title:(playingInBackground ? nowPlaying.title : nil)
                   artist:(playingInBackground ? nowPlaying.artist : nil)
                  playing:nowPlaying.isPlaying];
    if (showMusic && !playingInBackground) {
        self.musicLabel.text = nowPlaying.isPlaying ? @"正在播放" : @"未播放";
    }

    // The pull-down card uses its first row for time and battery health, not CPU.
    if (!self.forceSingleLine) {
        double celsius = PGBatteryTemperatureCelsius();
        self.metricsLabel.text = isnan(celsius) ? nil : [NSString stringWithFormat:@"♨ %.1f°C", celsius];
        self.metricsLabel.hidden = self.metricsLabel.text.length == 0;
    } else {
        [self updateMetricsText];
    }
    if (self.forceSingleLine || self.musicVisible || !preferences.twoLine) {
        self.timeLabel.text = [NSString stringWithFormat:@"%@  %@", time, battery];
        self.batteryLabel.text = nil;
        self.batteryLabel.hidden = YES;
    } else {
        self.timeLabel.text = time;
        self.batteryLabel.text = battery;
        self.batteryLabel.hidden = NO;
    }
    [self applyAppearance];
    [self setNeedsLayout];
    [self reportWidthIfNeeded];
}

- (void)handleMusicLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    if (self.onMusicLongPress) self.onMusicLongPress();
}

- (void)updateMetricsText {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (self.forceSingleLine && !preferences.landscapeMetrics) {
        self.metricsLabel.text = nil;
        self.metricsLabel.hidden = YES;
        return;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (!self.forceSingleLine || preferences.landscapeMetricsUsage) {
        // 下拉卡片固定显示 CPU 使用率；横屏常驻条仍尊重原来的频率/占用率设置。
        double usage = PGCPUUsagePercent();
        if (!isnan(usage)) {
            [parts addObject:[NSString stringWithFormat:@"CPU %2.0f%%", usage]];
        }
    } else {
        double gigahertz = PGCPUCurrentFrequencyGHz();
        if (gigahertz > 0.0) {
            if (gigahertz >= 1.0) {
                [parts addObject:[NSString stringWithFormat:@"%.2fGHz", gigahertz]];
            } else {
                [parts addObject:[NSString stringWithFormat:@"%.0fMHz", gigahertz * 1000.0]];
            }
        }
    }
    double celsius = PGBatteryTemperatureCelsius();
    if (!isnan(celsius)) {
        [parts addObject:[NSString stringWithFormat:@"%.1f\u00B0C", celsius]];
    }

    self.metricsLabel.text = parts.count ? [parts componentsJoinedByString:@" "] : nil;
    self.metricsLabel.hidden = parts.count == 0;
}

- (void)applyAppearance {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    UIFont *font = [self configuredFont];
    UIColor *textColor = preferences.textColor;

    for (UILabel *label in @[self.timeLabel, self.batteryLabel]) {
        label.font = font;
        label.textColor = textColor;
        label.numberOfLines = 1;
    }
    self.musicLabel.font = font;
    self.musicLabel.textColor = [textColor colorWithAlphaComponent:0.95];
    self.metricsLabel.font = font;
    self.metricsLabel.textColor = [textColor colorWithAlphaComponent:0.92];
    if (@available(iOS 13.0, *)) {
        self.musicStateView.tintColor = textColor;
    }
    self.divider.backgroundColor = [textColor colorWithAlphaComponent:0.30];
    self.metricsDivider.backgroundColor = [textColor colorWithAlphaComponent:0.30];

    if (self.forceSingleLine) {
        self.glassBlurView.hidden = YES;
        self.glassTintView.hidden = YES;
        self.glassSheenView.hidden = YES;
        UIColor *background = self.backgroundOverrideColor;
        if (!background) background = preferences.backgroundColorEnabled ? preferences.backgroundColor : UIColor.clearColor;
        self.backgroundColor = background;
    } else {
        self.glassBlurView.hidden = NO;
        self.glassTintView.hidden = NO;
        self.glassSheenView.hidden = NO;
        self.backgroundColor = UIColor.clearColor;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
    }
    // 有背景色就四角都圆；透明时圆角也保留（子类会按自己的半径覆盖），避免切换时跳变。
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                               kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
}

- (void)refreshAppearance {
    [self applyAppearance];
    [self setNeedsLayout];
    [self updateContents];
}

#pragma mark - 音乐区

- (void)setMusicVisible:(BOOL)visible title:(NSString *)title
                 artist:(NSString *)artist playing:(BOOL)playing {
    NSString *newTitle = title ?: @"";
    NSString *newArtist = artist ?: @"";
    BOOL changed = visible != self.musicVisible ||
                   playing != self.musicPlaying ||
                   ![newTitle isEqualToString:(self.musicTitle ?: @"")] ||
                   ![newArtist isEqualToString:(self.musicArtist ?: @"")];
    if (!changed) return;

    self.musicVisible = visible;
    self.musicPlaying = playing;
    self.musicTitle = newTitle;
    self.musicArtist = newArtist;

    if (visible) {
        NSString *composed = nil;
        if (self.musicTitle.length && self.musicArtist.length) {
            composed = [NSString stringWithFormat:@"\u266A %@ \u00B7 %@", self.musicTitle, self.musicArtist];
        } else if (self.musicTitle.length) {
            composed = [NSString stringWithFormat:@"\u266A %@", self.musicTitle];
        } else if (self.musicArtist.length) {
            composed = [NSString stringWithFormat:@"\u266A %@", self.musicArtist];
        } else {
            composed = @"\u266A 正在播放";
        }
        self.musicLabel.text = composed;
        // Playback controls live only in the long-press modal panel.
        self.musicStateView.image = nil;
    } else {
        self.musicLabel.text = nil;
        self.musicStateView.image = nil;
    }

    self.musicLabel.hidden = !visible;
    self.musicArtworkView.hidden = !visible || self.musicArtworkView.image == nil;
    self.musicStateView.hidden = !visible;
    self.divider.hidden = !visible;
    // 字体/颜色必须先就位再量宽度，否则首次量到的是系统默认字号。
    [self applyAppearance];
    [self setNeedsLayout];
    [self reportWidthIfNeeded];
}

- (CGFloat)musicIntrinsicWidth {
    if (!self.musicVisible || self.musicLabel.text.length == 0) return 0.0;
    CGSize size = [self.musicLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    return MIN(ceil(size.width), PGMusicMaxTextWidth);
}

/// 内容宽度变化时通知宿主重排（胶囊会跟着歌名变宽变窄）。
- (void)reportWidthIfNeeded {
    if (self.reportingSize) return;
    CGFloat width = [self intrinsicWidth];
    if (fabs(width - self.reportedWidth) < 1.0 && self.reportedMusicVisible == self.musicVisible) return;
    self.reportedWidth = width;
    self.reportedMusicVisible = self.musicVisible;
    if (!self.contentWidthDidChange) return;
    self.reportingSize = YES;
    self.contentWidthDidChange();
    self.reportingSize = NO;
}

/// 不含 maxWidth 限制的"贴合内容"宽度。
- (CGFloat)intrinsicWidth {
    if (self.forceSingleLine) {
        CGFloat width = 2.0 * PGSingleLinePadding;
        if (self.metricsLabel.text.length > 0 && !self.metricsLabel.hidden) {
            // 指标文字 + 分隔线两侧间距
            CGSize metricsSize = [self.metricsLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
            width += ceil(metricsSize.width) + PGSingleLineSectionGap + 1.0 + PGSingleLineSectionGap;
        }
        CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        width += ceil(timeSize.width);
        if (self.musicVisible) {
            // Divider spacing plus the music text only; controls are in the long-press panel.
            width += PGSingleLineSectionGap + 1.0 + PGSingleLineSectionGap;
            width += [self musicIntrinsicWidth];
        }
        return width;
    }

    CGFloat firstRowWidth = 0.0;
    if (self.timeLabel.text.length > 0) {
        firstRowWidth = ceil([self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width);
    }
    if (self.metricsLabel.text.length > 0 && !self.metricsLabel.hidden) {
        firstRowWidth += 17.0 + ceil([self.metricsLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width);
    }
    if (!self.musicVisible && !self.batteryLabel.hidden && self.batteryLabel.text.length > 0) {
        firstRowWidth = MAX(firstRowWidth, ceil([self.batteryLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width));
    }
    CGFloat secondRowWidth = 0.0;
    if (self.musicVisible) {
        secondRowWidth = [self musicIntrinsicWidth] + 8.0;
        if (self.musicArtworkView.image) secondRowWidth += 35.0;
    }
    return MAX(firstRowWidth, secondRowWidth) + 20.0;
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.forceSingleLine) {
        [self layoutSingleLine];
        return;
    }

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat pad = 10.0;
    // The card is one unified two-row layout when music metadata is present.
    CGFloat rowHeight = height / (self.musicVisible || preferences.twoLine ? 2.0 : 1.0);
    CGFloat scale = MAX(UIScreen.mainScreen.scale, 1.0);
    CGFloat lineHeight = MIN(14.0, rowHeight - 4.0);

    self.glassBlurView.frame = self.bounds;
    self.glassTintView.frame = self.bounds;
    self.glassSheenView.frame = self.bounds;
    self.glassTintGradient.frame = self.glassTintView.bounds;
    self.glassSheenGradient.frame = self.glassSheenView.bounds;
    self.divider.hidden = YES;
    self.metricsDivider.hidden = YES;
    self.musicLabel.hidden = !self.musicVisible;
    self.musicStateView.hidden = YES;

    CGFloat firstRowBottom = rowHeight;
    CGFloat right = width - pad;
    BOOL hasMetrics = self.metricsLabel.text.length > 0;
    self.metricsLabel.hidden = !hasMetrics;
    self.metricsDivider.hidden = !hasMetrics;

    // First row: time/battery and temperature; second row: cover plus available song metadata.

    // 播放控制仍由整卡长按弹出，不在卡片内常驻显示。
    CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, rowHeight)];
    CGFloat timeWidth = MIN(ceil(timeSize.width), MAX(0.0, right - pad));
    self.timeLabel.textAlignment = hasMetrics ? NSTextAlignmentLeft : NSTextAlignmentCenter;

    if (hasMetrics) {
        CGSize metricsSize = [self.metricsLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, rowHeight)];
        CGFloat metricsWidth = MIN(ceil(metricsSize.width), MAX(0.0, right - pad));
        CGFloat available = MAX(0.0, width - 2.0 * pad - 17.0);
        if (timeWidth + metricsWidth > available) {
            CGFloat total = MAX(1.0, timeWidth + metricsWidth);
            CGFloat ratio = available / total;
            timeWidth = floor(timeWidth * ratio);
            metricsWidth = MAX(0.0, available - timeWidth);
        }
        self.timeLabel.frame = CGRectMake(pad, 0.0, timeWidth, firstRowBottom);
        CGFloat dividerX = pad + timeWidth + 8.0;
        self.metricsDivider.frame = CGRectMake(dividerX, (firstRowBottom - lineHeight) / 2.0, 1.0 / scale, lineHeight);
        CGFloat metricsX = dividerX + 9.0;
        self.metricsLabel.textAlignment = NSTextAlignmentRight;
        self.metricsLabel.frame = CGRectMake(metricsX, 0.0, MAX(0.0, right - metricsX), firstRowBottom);
    } else {
        self.metricsLabel.frame = CGRectZero;
        self.metricsDivider.frame = CGRectZero;
        self.timeLabel.frame = CGRectMake(pad, 0.0, MAX(0.0, width - 2.0 * pad), firstRowBottom);
    }

    if (self.musicVisible) {
        self.batteryLabel.hidden = YES;
        self.batteryLabel.frame = CGRectZero;
        self.musicStateView.frame = CGRectZero;
        self.musicStateView.hidden = YES;
        CGFloat musicLeft = pad;
        if (self.musicArtworkView.image) {
            CGFloat artworkSize = MIN(36.0, MAX(18.0, rowHeight - 6.0));
            self.musicArtworkView.hidden = NO;
            self.musicArtworkView.frame = CGRectMake(musicLeft, rowHeight + (rowHeight - artworkSize) / 2.0, artworkSize, artworkSize);
            musicLeft += artworkSize + 8.0;
        } else {
            self.musicArtworkView.hidden = YES;
            self.musicArtworkView.frame = CGRectZero;
        }
        self.musicLabel.frame = CGRectMake(musicLeft, rowHeight, MAX(0.0, right - musicLeft), rowHeight);
    } else {
        self.musicLabel.frame = CGRectZero;
        self.musicStateView.frame = CGRectZero;
        if (preferences.twoLine) {
            self.batteryLabel.textAlignment = NSTextAlignmentCenter;
            self.batteryLabel.frame = CGRectMake(pad, rowHeight, width - 2.0 * pad, height - rowHeight);
        } else {
            self.batteryLabel.frame = CGRectZero;
            self.batteryLabel.hidden = YES;
        }
    }
}

/// Unified music metadata row; playback actions are available in the long-press panel.
- (void)layoutSingleLine {
    self.glassBlurView.frame = self.bounds;
    self.glassTintView.frame = self.bounds;
    self.glassSheenView.frame = self.bounds;
    self.glassTintGradient.frame = self.glassTintView.bounds;
    self.glassSheenGradient.frame = self.glassSheenView.bounds;
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat pad = PGSingleLinePadding;
    CGFloat scale = MAX(UIScreen.mainScreen.scale, 1.0);
    CGFloat lineHeight = MIN(14.0, height - 6.0);
    CGFloat contentRight = width - pad;

    self.batteryLabel.frame = CGRectZero;
    self.batteryLabel.hidden = YES;

    // 第一段：CPU 频率 + 电池温度（没内容就整段让位给时间）。
    CGFloat cursor = pad;
    if (self.metricsLabel.text.length > 0 && !self.metricsLabel.hidden) {
        self.metricsLabel.hidden = NO;
        CGSize metricsSize = [self.metricsLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)];
        CGFloat metricsWidth = MIN(ceil(metricsSize.width), MAX(0.0, contentRight - pad));
        self.metricsLabel.frame = CGRectMake(cursor, 0.0, metricsWidth, height);
        cursor += metricsWidth + PGSingleLineSectionGap;
        self.metricsDivider.hidden = NO;
        self.metricsDivider.frame = CGRectMake(cursor, (height - lineHeight) / 2.0, 1.0 / scale, lineHeight);
        cursor += 1.0 + PGSingleLineSectionGap;
    } else {
        self.metricsLabel.frame = CGRectZero;
        self.metricsDivider.hidden = YES;
        self.metricsDivider.frame = CGRectZero;
    }

    if (!self.musicVisible) {
        // 没有音乐时，时间在剩下的空间里居中（有指标时是"指标右边的剩余空间"）。
        self.timeLabel.textAlignment = NSTextAlignmentCenter;
        self.timeLabel.frame = CGRectMake(cursor, 0.0, MAX(0.0, contentRight - cursor), height);
        self.musicLabel.frame = CGRectZero;
        self.musicStateView.frame = CGRectZero;
        self.divider.frame = CGRectZero;
        return;
    }

    CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)];
    CGFloat timeWidth = MIN(ceil(timeSize.width), MAX(0.0, contentRight - cursor));
    self.timeLabel.textAlignment = NSTextAlignmentLeft;
    self.timeLabel.frame = CGRectMake(cursor, 0.0, timeWidth, height);

    cursor += timeWidth + PGSingleLineSectionGap;
    self.divider.frame = CGRectMake(cursor, (height - lineHeight) / 2.0, 1.0 / scale, lineHeight);

    cursor += 1.0 + PGSingleLineSectionGap;
    CGFloat musicWidth = MAX(0.0, contentRight - cursor);
    self.musicLabel.frame = CGRectMake(cursor, 0.0, musicWidth, height);
    self.musicStateView.frame = CGRectZero;
    self.musicStateView.hidden = YES;
}

#pragma mark - 尺寸

- (CGSize)preferredContentSizeForMaxWidth:(CGFloat)maxWidth {
    // 先刷新一次内容，否则宿主首次排版时标签还是空的，量出来的宽度不可用。
    [self updateContents];
    UIFont *font = [self configuredFont];

    if (self.forceSingleLine) {
        CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        CGFloat width = MIN([self intrinsicWidth], MAX(44.0, maxWidth));
        CGFloat height = MAX(ceil(MAX(timeSize.height, font.lineHeight)) + 12.0, 22.0);
        return CGSizeMake(width, height);
    }

    CGFloat textWidth = 0.0;
    CGFloat textHeight = 0.0;
    CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    textWidth = MAX(textWidth, timeSize.width);
    textHeight = MAX(textHeight, timeSize.height);
    if (self.metricsLabel.text.length > 0 && !self.metricsLabel.hidden) {
        CGSize metricsSize = [self.metricsLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        textWidth += 17.0 + metricsSize.width;
    }
    if (!self.musicVisible && !self.batteryLabel.hidden && self.batteryLabel.text.length > 0) {
        CGSize batterySize = [self.batteryLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        textWidth = MAX(textWidth, batterySize.width);
        textHeight += batterySize.height;
    }
    if (self.musicVisible) {
        CGSize musicSize = [self.musicLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        textWidth = MAX(textWidth, musicSize.width + 22.0);
        textHeight = MAX(textHeight, timeSize.height) + MAX(musicSize.height, font.lineHeight);
    }
    if (textHeight <= 0.0) {
        textWidth = font.pointSize * 6.0;
        textHeight = font.lineHeight;
    }

    // Left/right padding is 10pt; the optional second row contains only actual media metadata.
    CGFloat width = ceil(textWidth) + 20.0;
    CGFloat height = ceil(textHeight) + 8.0;
    return CGSizeMake(MIN(width, MAX(44.0, maxWidth)), MAX(height, 20.0));
}

#pragma mark - 刷新

- (void)startUpdating {
    [self stopUpdating];
    [PGNowPlaying.sharedInstance startMonitoring];
    [self refreshAppearance];
    [self updateContents];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(updateContents)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)stopUpdating {
    [self.timer invalidate];
    self.timer = nil;
    if (!PerfectGrabberPreferences.sharedPreferences.landscapeAlwaysOn) {
        [PGNowPlaying.sharedInstance stopMonitoring];
    }
}

@end
