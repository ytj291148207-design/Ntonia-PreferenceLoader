//
//  Tweak.m
//  GrabberCard —寄生在原生 Notification Center 抓取卡片上的信息面板
//
//  目标设备: iPhone 14 Pro Max / iOS 16.3.1 / Dopamine rootless
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <notify.h>
#import "PGPrefs.h"

#define PG_RANGE(m, i) [m rangeAtIndex:(i)]

#pragma mark - 小工具

static UIImage *PGSymbol(NSString *name, CGFloat pointSize, UIImageSymbolWeight weight) {
    UIImage *image = [UIImage systemImageNamed:name];
    if (!image) return nil;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight];
    return [image imageWithConfiguration:config];
}

static UIColor *PGAccentColor(void) {
    return [UIColor colorWithRed:0.36 green:0.75 blue:1.0 alpha:1.0];
}

static UIColor *PGTextColor(CGFloat alpha) {
    return [UIColor colorWithWhite:1.0 alpha:alpha];
}

static void PGHapticLight(void) {
    static id generator = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"UIImpactFeedbackGenerator");
        if (cls) {
            generator = [[cls alloc] initWithStyle:0];
        }
    });
    if (generator) {
        if ([generator respondsToSelector:@selector(prepare)]) {
            ((void (*)(id, SEL))objc_msgSend)(generator, @selector(prepare));
        }
        if ([generator respondsToSelector:@selector(impactOccurred)]) {
            ((void (*)(id, SEL))objc_msgSend)(generator, @selector(impactOccurred));
        }
        return;
    }
    AudioServicesPlaySystemSound(1519);
}

static UIFont *PGFont(CGFloat size) {
    NSInteger weightIndex = PGGetInt(@"fontWeight", 2);
    CGFloat scale = PGGetFloat(@"fontScale", 1.0);
    UIFontWeight weight = UIFontWeightSemibold;
    switch (weightIndex) {
        case 0: weight = UIFontWeightRegular; break;
        case 1: weight = UIFontWeightMedium; break;
        case 3: weight = UIFontWeightBold; break;
        default: weight = UIFontWeightSemibold; break;
    }
    return [UIFont systemFontOfSize:MAX(9.0, size * scale) weight:weight];
}

static NSString *PGTimeString(void) {
    static NSDateFormatter *formatter24 = nil;
    static NSDateFormatter *formatter12 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter24 = [[NSDateFormatter alloc] init];
        formatter24.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter24.dateFormat = @"HH:mm";

        formatter12 = [[NSDateFormatter alloc] init];
        formatter12.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter12.dateFormat = @"h:mm a";
    });
    BOOL use24 = PGGetBool(@"use24Hour", YES);
    return [(use24 ? formatter24 : formatter12) stringFromDate:[NSDate date]] ?: @"";
}

static NSString *PGClockString(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    NSInteger total = (NSInteger)round(seconds);
    NSInteger m = total / 60;
    NSInteger s = total % 60;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)m, (long)s];
}

#pragma mark - MediaRemote

typedef CFDictionaryRef (*PGMRGetNowPlayingInfoFn)(void);
typedef void (*PGMRRegisterForNotificationsFn)(dispatch_queue_t);
typedef void (*PGMRSendCommandFn)(NSInteger, id);

static PGMRGetNowPlayingInfoFn PGMRGetNowPlayingInfoFunc;
static PGMRRegisterForNotificationsFn PGMRRegisterFunc;
static PGMRSendCommandFn PGMRSendCommandFunc;

static NSString *PGMRTitleKey;
static NSString *PGMRArtistKey;
static NSString *PGMRAlbumKey;
static NSString *PGMRDurationKey;
static NSString *PGMRElapsedKey;
static NSString *PGMRRateKey;
static NSString *PGMRArtworkKey;
static NSString *PGMRBundleKey;
static NSString *PGMRInfoChangedNote;

static NSString *PGMRConstantString(void *handle, const char *symbol, NSString *fallback) {
    if (!handle) return fallback;
    CFStringRef *ref = (CFStringRef *)dlsym(handle, symbol);
    if (ref && *ref) return (__bridge NSString *)(*ref);
    return fallback;
}

static void PGLoadMediaRemote(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!handle) return;

        PGMRGetNowPlayingInfoFunc = (PGMRGetNowPlayingInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        PGMRRegisterFunc = (PGMRRegisterForNotificationsFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        PGMRSendCommandFunc = (PGMRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");

        PGMRTitleKey    = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoTitle", @"Title");
        PGMRArtistKey   = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoArtist", @"Artist");
        PGMRAlbumKey    = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoAlbum", @"Album");
        PGMRDurationKey = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoDuration", @"Duration");
        PGMRElapsedKey  = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoElapsedTime", @"Elapsed Time");
        PGMRRateKey     = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoPlaybackRate", @"Rate");
        PGMRArtworkKey  = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoArtworkData", @"ArtworkData");
        PGMRBundleKey   = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoBundleIdentifier", @"BundleIdentifier");
        PGMRInfoChangedNote = PGMRConstantString(handle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification", @"kMRMediaRemoteNowPlayingInfoDidChangeNotification");
    });
}

static NSDictionary *PGNowPlayingInfo(void) {
    if (!PGMRGetNowPlayingInfoFunc) return nil;
    CFDictionaryRef ref = PGMRGetNowPlayingInfoFunc();
    if (!ref) return nil;
    return CFBridgingRelease(ref);
}

static void PGSendMediaCommand(NSInteger command, NSDictionary *userInfo) {
    if (!PGMRSendCommandFunc) return;
    PGMRSendCommandFunc(command, userInfo);
}

#pragma mark - 歌词

@interface PGLyricsProvider : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, strong) NSArray<NSDictionary *> *lines;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL unavailable;
@property (nonatomic, copy) NSString *requestKey;
- (void)updateWithTitle:(NSString *)title artist:(NSString *)artist;
- (NSString *)lineAtTime:(NSTimeInterval)time;
- (void)reset;
@end

@implementation PGLyricsProvider

- (instancetype)init {
    if ((self = [super init])) {
        _lines = @[];
    }
    return self;
}

- (void)reset {
    _lines = @[];
    _loading = NO;
    _unavailable = NO;
    _requestKey = nil;
}

- (NSString *)cachePathForKey:(NSString *)key {
    NSString *name = [NSString stringWithFormat:@"%lu.lrc", (unsigned long)[key hash]];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/GrabberCard"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:name];
}

- (void)updateWithTitle:(NSString *)title artist:(NSString *)artist {
    if (!PGGetBool(@"showLyrics", YES)) { [self reset]; return; }

    NSString *cleanTitle = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *cleanArtist = [artist stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanTitle.length == 0) { [self reset]; return; }

    NSString *key = [[cleanTitle lowercaseString] stringByAppendingFormat:@"|%@", [cleanArtist lowercaseString]];
    if ([_requestKey isEqualToString:key] && (_lines.count > 0 || _loading || _unavailable)) return;

    _requestKey = key;
    _title = cleanTitle;
    _artist = cleanArtist;
    _lines = @[];
    _unavailable = NO;

    NSString *cached = [NSString stringWithContentsOfFile:[self cachePathForKey:key] encoding:NSUTF8StringEncoding error:nil];
    if (cached.length) {
        _lines = [self parseLRC:cached];
        if (_lines.count) return;
    }

    [self fetchLyricsForKey:key title:cleanTitle artist:cleanArtist];
}

- (NSArray<NSDictionary *> *)parseLRC:(NSString *)lrc {
    if (!lrc || lrc.length == 0) return @[];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\](.*)"
                                                                           options:0 error:nil];
    [lrc enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (matches.count == 0) return;
        NSTextCheckingResult *match = matches[0];
        if ([match rangeAtIndex:1].location == NSNotFound || [match rangeAtIndex:2].location == NSNotFound) return;
        NSInteger minutes = [[line substringWithRange:[match rangeAtIndex:1]] integerValue];
        NSInteger seconds = [[line substringWithRange:[match rangeAtIndex:2]] integerValue];
        CGFloat fraction = 0.0;
        if ([match rangeAtIndex:3].location != NSNotFound && [match rangeAtIndex:3].length > 0) {
            NSString *fractionString = [line substringWithRange:[match rangeAtIndex:3]];
            CGFloat value = [fractionString floatValue];
            fraction = ([match rangeAtIndex:3].length == 1) ? (value / 10.0) : (value / 100.0);
        }
        NSString *text = @"";
        if ([match rangeAtIndex:4].location != NSNotFound && [match rangeAtIndex:4].length > 0) {
            text = [[line substringWithRange:[match rangeAtIndex:4]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (text.length == 0) return;
        NSTimeInterval time = minutes * 60 + seconds + fraction;
        [result addObject:@{@"time" : @(time), @"text" : text}];
    }];
    if (result.count < 2) return @[];
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSTimeInterval ta = [a[@"time"] doubleValue];
        NSTimeInterval tb = [b[@"time"] doubleValue];
        if (ta < tb) return NSOrderedAscending;
        if (ta > tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return [result copy];
}

- (void)fetchLyricsForKey:(NSString *)key title:(NSString *)title artist:(NSString *)artist {
    _loading = YES;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 7.0;
    config.timeoutIntervalForResource = 12.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSString *query = [NSString stringWithFormat:@"%@ %@", title, artist ?: @""];
    NSString *encoded = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *searchURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://music.163.com/api/search/get/web?type=1&limit=5&s=%@", encoded]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:searchURL];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://music.163.com/" forHTTPHeaderField:@"Referer"];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            if (![self.requestKey isEqualToString:key]) return;
            if (error || !data) { self.unavailable = YES; return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *songs = [json valueForKeyPath:@"result.songs"];
            if (![songs isKindOfClass:[NSArray class]] || songs.count == 0) { self.unavailable = YES; return; }

            NSDictionary *picked = nil;
            NSString *wanted = [title lowercaseString];
            for (NSDictionary *song in songs) {
                NSString *name = [song[@"name"] lowercaseString];
                if (name && ([name containsString:wanted] || [wanted containsString:name])) { picked = song; break; }
            }
            if (!picked) picked = songs[0];

            NSNumber *songID = picked[@"id"];
            if (![songID isKindOfClass:[NSNumber class]]) { self.unavailable = YES; return; }
            [self fetchLyricWithID:songID key:key session:session];
        });
    }];
    [task resume];
}

- (void)fetchLyricWithID:(NSNumber *)songID key:(NSString *)key session:(NSURLSession *)session {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://music.163.com/api/song/lyric?id=%@&lv=1&kv=1&tv=-1", songID]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://music.163.com/" forHTTPHeaderField:@"Referer"];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.requestKey isEqualToString:key]) return;
            if (error || !data) { self.unavailable = YES; return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *lrc = [json valueForKeyPath:@"lrc.lyric"];
            NSArray *lines = [self parseLRC:lrc];
            if (lines.count == 0) { self.unavailable = YES; return; }
            self.lines = lines;
            self.unavailable = NO;
            [lrc writeToFile:[self cachePathForKey:key] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        });
    }];
    [task resume];
}

- (NSString *)lineAtTime:(NSTimeInterval)time {
    if (_lines.count == 0) return nil;
    NSString *current = nil;
    for (NSDictionary *line in _lines) {
        if ([line[@"time"] doubleValue] <= time) current = line[@"text"];
        else break;
    }
    return current;
}

@end

#pragma mark - 信息采集

static NSInteger PGBatteryPercent(void) {
    Class cls = NSClassFromString(@"SBUIController");
    if (cls) {
        id controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
        if (controller && [controller respondsToSelector:@selector(batteryCapacityAsPercentage)]) {
            NSInteger value = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(batteryCapacityAsPercentage));
            if (value > 0 && value <= 100) return value;
        }
    }
    return -1;
}

static BOOL PGBatteryIsCharging(void) {
    Class cls = NSClassFromString(@"SBUIController");
    if (cls) {
        id controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
        if (controller && [controller respondsToSelector:@selector(isOnAC)]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(controller, @selector(isOnAC));
        }
    }
    return NO;
}

extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
extern CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
extern CFDictionaryRef IOPSCopyPowerSourcesDescription(CFTypeRef blob, CFTypeRef source);

static NSDictionary *PGPowerSourceDescription(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return nil;
    NSDictionary *result = nil;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    if (list && CFArrayGetCount(list) > 0) {
        CFTypeRef source = CFArrayGetValueAtIndex(list, 0);
        CFDictionaryRef description = IOPSCopyPowerSourcesDescription(info, source);
        if (description) {
            result = [NSDictionary dictionaryWithDictionary:(__bridge NSDictionary *)description];
            CFRelease(description);
        }
    }
    if (list) CFRelease(list);
    CFRelease(info);
    return result;
}

static CGFloat PGBatteryTemperature(void) {
    NSDictionary *source = PGPowerSourceDescription();
    id value = source[@"Temperature"];
    if (![value respondsToSelector:@selector(doubleValue)]) return NAN;
    CGFloat raw = [value doubleValue];
    if (raw <= 0) return NAN;
    CGFloat celsius = raw > 150 ? raw / 10.0 : raw;
    if (celsius < 0 || celsius > 90) return NAN;
    return celsius;
}

static CGFloat PGCPUPercent(void) {
    static natural_t previousUser = 0, previousSystem = 0, previousIdle = 0, previousNice = 0;
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_info(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) return 0;

    natural_t user = info.cpu_ticks[CPU_STATE_USER];
    natural_t nice = info.cpu_ticks[CPU_STATE_NICE];
    natural_t system = info.cpu_ticks[CPU_STATE_SYSTEM];
    natural_t idle = info.cpu_ticks[CPU_STATE_IDLE];

    natural_t total = (user + nice + system + idle) - (previousUser + previousNice + previousSystem + previousIdle);
    natural_t used = (user + nice + system) - (previousUser + previousNice + previousSystem);

    previousUser = user;
    previousNice = nice;
    previousSystem = system;
    previousIdle = idle;

    if (total == 0) return 0;
    CGFloat percent = (CGFloat)used / (CGFloat)total * 100.0;
    return MIN(100.0, MAX(0.0, percent));
}

#pragma mark - 进度条

@interface PGProgressBar : UIControl
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) BOOL hapticEnabled;
@property (nonatomic, copy) void (^onSeek)(CGFloat progress);
@property (nonatomic, copy) void (^onScrub)(CGFloat progress);
@end

@implementation PGProgressBar {
    UIView *_trackView;
    UIView *_fillView;
    UIView *_knobView;
    CGFloat _lastHapticStep;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _trackView = [[UIView alloc] init];
        _trackView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
        _trackView.layer.cornerRadius = 2.0;
        _trackView.layer.masksToBounds = YES;
        [self addSubview:_trackView];

        _fillView = [[UIView alloc] init];
        _fillView.backgroundColor = PGAccentColor();
        _fillView.layer.cornerRadius = 2.0;
        _fillView.layer.masksToBounds = YES;
        [self addSubview:_fillView];

        _knobView = [[UIView alloc] init];
        _knobView.backgroundColor = [UIColor whiteColor];
        _knobView.layer.cornerRadius = 6.0;
        _knobView.layer.shadowColor = [UIColor blackColor].CGColor;
        _knobView.layer.shadowOpacity = 0.35;
        _knobView.layer.shadowRadius = 3.0;
        _knobView.layer.shadowOffset = CGSizeMake(0, 1);
        [self addSubview:_knobView];

        _lastHapticStep = -1;
    }
    return self;
}

- (void)setProgress:(CGFloat)progress {
    progress = MIN(1.0, MAX(0.0, progress));
    _progress = progress;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGFloat trackHeight = 4.0;
    CGFloat centerY = height / 2.0;
    _trackView.frame = CGRectMake(0, centerY - trackHeight / 2.0, width, trackHeight);
    _fillView.frame = CGRectMake(0, centerY - trackHeight / 2.0, MAX(0, width * _progress), trackHeight);
    CGFloat knobSize = 12.0;
    _knobView.frame = CGRectMake(MAX(0, MIN(width - knobSize, width * _progress - knobSize / 2.0)), centerY - knobSize / 2.0, knobSize, knobSize);
    _knobView.layer.cornerRadius = knobSize / 2.0;
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self updateProgressWithTouch:touch];
    self.transform = CGAffineTransformIdentity;
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self updateProgressWithTouch:touch];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self updateProgressWithTouch:touch];
    if (self.onSeek) self.onSeek(self.progress);
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [super cancelTrackingWithEvent:event];
    if (self.onSeek) self.onSeek(self.progress);
}

- (void)updateProgressWithTouch:(UITouch *)touch {
    CGPoint point = [touch locationInView:self];
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return;
    CGFloat progress = point.x / width;
    progress = MIN(1.0, MAX(0.0, progress));

    if (fabs(progress - _progress) < 0.0005) return;
    self.progress = progress;

    if (self.hapticEnabled) {
        NSInteger step = (NSInteger)floor(progress * 100.0);
        if (step != (NSInteger)_lastHapticStep) {
            _lastHapticStep = step;
            PGHapticLight();
        }
    }

    if (self.onScrub) self.onScrub(progress);
}

@end

#pragma mark - 卡片

@interface PGCardView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, assign) BOOL hasMusic;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) NSTimeInterval elapsed;
@property (nonatomic, assign) double playbackRate;
@property (nonatomic, assign) BOOL scrubbing;
@property (nonatomic, copy) void (^onCollapse)(void);
@property (nonatomic, copy) void (^onExpandedChange)(void);
- (void)applyPreferences;
- (void)refresh;
- (void)flashIn;
- (void)collapseAnimated:(BOOL)animated completion:(void (^)(void))completion;
@end

@implementation PGCardView {
    UIVisualEffectView *_effectView;
    UIImageView *_noiseView;
    CALayer *_borderLayer;
    CALayer *_separatorLayer;
    UIView *_handleView;
    UIButton *_collapseButton;

    UILabel *_timeLabel;
    UILabel *_batteryLabel;
    UILabel *_tempLabel;
    UILabel *_cpuLabel;

    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UILabel *_lyricsLabel;
    UILabel *_emptyLabel;

    PGProgressBar *_progressBar;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
    UIButton *_previousButton;
    UIButton *_playButton;
    UIButton *_nextButton;

    NSTimer *_timer;
    PGLyricsProvider *_lyrics;
    UIImage *_currentArtwork;
    NSString *_lastTitle;
    NSString *_lastArtist;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _lyrics = [[PGLyricsProvider alloc] init];
        _playbackRate = 1.0;
        [self buildSubviews];
        [self applyPreferences];
        [self startTimer];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)buildSubviews {
    self.backgroundColor = [UIColor clearColor];
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 12.0;
    self.layer.shadowOffset = CGSizeMake(0, 6);
    self.clipsToBounds = NO;

    _handleView = [[UIView alloc] init];
    _handleView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    _handleView.layer.cornerRadius = 2.0;
    [self addSubview:_handleView];

    _collapseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_collapseButton setImage:PGSymbol(@"chevron.up", 13, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    _collapseButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    _collapseButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _collapseButton.layer.cornerRadius = 13.0;
    [_collapseButton addTarget:self action:@selector(collapseTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_collapseButton];

    _timeLabel = [[UILabel alloc] init];
    _timeLabel.textColor = PGTextColor(1.0);
    _timeLabel.backgroundColor = [UIColor clearColor];
    _timeLabel.font = PGFont(30);
    _timeLabel.adjustsFontSizeToFitWidth = YES;
    _timeLabel.minimumFontSize = 16;
    [self addSubview:_timeLabel];

    _batteryLabel = [[UILabel alloc] init];
    _batteryLabel.textColor = PGTextColor(0.92);
    _batteryLabel.backgroundColor = [UIColor clearColor];
    _batteryLabel.font = PGFont(13);
    [self addSubview:_batteryLabel];

    _tempLabel = [[UILabel alloc] init];
    _tempLabel.textColor = PGTextColor(0.92);
    _tempLabel.backgroundColor = [UIColor clearColor];
    _tempLabel.font = PGFont(13);
    [self addSubview:_tempLabel];

    _cpuLabel = [[UILabel alloc] init];
    _cpuLabel.textColor = PGTextColor(0.92);
    _cpuLabel.backgroundColor = [UIColor clearColor];
    _cpuLabel.font = PGFont(13);
    [self addSubview:_cpuLabel];

    _artView = [[UIImageView alloc] init];
    _artView.contentMode = _currentArtwork ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter;
    _artView.clipsToBounds = YES;
    _artView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _artView.layer.cornerRadius = 12.0;
    [self addSubview:_artView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.textColor = PGTextColor(0.98);
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = PGFont(16);
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.textColor = PGTextColor(0.62);
    _subtitleLabel.backgroundColor = [UIColor clearColor];
    _subtitleLabel.font = PGFont(12);
    _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_subtitleLabel];

    _lyricsLabel = [[UILabel alloc] init];
    _lyricsLabel.textColor = [UIColor colorWithRed:0.72 green:0.85 blue:1.0 alpha:0.85];
    _lyricsLabel.backgroundColor = [UIColor clearColor];
    _lyricsLabel.font = PGFont(12);
    _lyricsLabel.numberOfLines = 2;
    _lyricsLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_lyricsLabel];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.textColor = PGTextColor(0.55);
    _emptyLabel.backgroundColor = [UIColor clearColor];
    _emptyLabel.font = PGFont(14);
    _emptyLabel.text = @"未播放";
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_emptyLabel];

    _progressBar = [[PGProgressBar alloc] init];
    _progressBar.hapticEnabled = PGGetBool(@"sliderHaptic", YES);
    __weak PGCardView *weakSelf = self;
    _progressBar.onScrub = ^(CGFloat progress) {
        PGCardView *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.scrubbing = YES;
        strongSelf.elapsed = progress * strongSelf.duration;
        [strongSelf updateProgressLabels];
    };
    _progressBar.onSeek = ^(CGFloat progress) {
        PGCardView *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.scrubbing = NO;
        strongSelf.elapsed = progress * strongSelf.duration;
        NSDictionary *userInfo = @{PGMRElapsedKey ?: @"Elapsed Time" : @(progress * strongSelf.duration)};
        PGSendMediaCommand(6, userInfo);
    };
    [self addSubview:_progressBar];

    _elapsedLabel = [[UILabel alloc] init];
    _elapsedLabel.textColor = PGTextColor(0.55);
    _elapsedLabel.backgroundColor = [UIColor clearColor];
    _elapsedLabel.font = PGFont(10);
    [self addSubview:_elapsedLabel];

    _durationLabel = [[UILabel alloc] init];
    _durationLabel.textColor = PGTextColor(0.55);
    _durationLabel.backgroundColor = [UIColor clearColor];
    _durationLabel.font = PGFont(10);
    _durationLabel.textAlignment = NSTextAlignmentRight;
    [self addSubview:_durationLabel];

    _previousButton = [self buildControlButton:@"backward.fill" action:@selector(previousTapped)];
    _playButton = [self buildControlButton:@"play.fill" action:@selector(playPauseTapped)];
    _nextButton = [self buildControlButton:@"forward.fill" action:@selector(nextTapped)];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.38;
    longPress.cancelsTouchesInView = NO;
    longPress.delegate = self;
    [self addGestureRecognizer:longPress];
}

- (UIButton *)buildControlButton:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:PGSymbol(symbol, 17, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    button.tintColor = PGTextColor(0.95);
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    button.layer.cornerRadius = 17.0;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];
    return button;
}

- (void)applyPreferences {
    CGFloat radius = PGGetFloat(@"cornerRadius", 24.0);
    self.layer.cornerRadius = radius;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;

    [_effectView removeFromSuperview];
    _effectView = nil;

    UIBlurEffectStyle style = UIBlurEffectStyleSystemMaterial;
    switch (PGGetInt(@"backgroundStyle", 0)) {
        case 1: style = UIBlurEffectStyleSystemUltraThinMaterial; break;
        case 2: style = UIBlurEffectStyleSystemThickMaterial; break;
        default: style = UIBlurEffectStyleSystemMaterial; break;
    }
    _effectView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
    _effectView.frame = self.bounds;
    _effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _effectView.layer.cornerRadius = radius;
    _effectView.layer.masksToBounds = YES;
    _effectView.alpha = PGGetFloat(@"opacity", 0.92);
    [self insertSubview:_effectView atIndex:0];

    [self rebuildNoiseViewIfNeeded];

    if (!_borderLayer) {
        _borderLayer = [CALayer layer];
        _borderLayer.borderWidth = 0.8;
        _borderLayer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
        [self.layer addSublayer:_borderLayer];
    }
    _borderLayer.frame = self.bounds;
    _borderLayer.cornerRadius = radius;
    _borderLayer.shadowColor = [UIColor blackColor].CGColor;
    _borderLayer.shadowOpacity = 0.20;
    _borderLayer.shadowRadius = 10.0;
    _borderLayer.shadowOffset = CGSizeMake(0, 4);
    _borderLayer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;

    _timeLabel.font = PGFont(30);
    _batteryLabel.font = PGFont(13);
    _tempLabel.font = PGFont(13);
    _cpuLabel.font = PGFont(13);
    _titleLabel.font = PGFont(16);
    _subtitleLabel.font = PGFont(12);
    _lyricsLabel.font = PGFont(12);
    _emptyLabel.font = PGFont(14);
    _elapsedLabel.font = PGFont(10);
    _durationLabel.font = PGFont(10);
    _progressBar.hapticEnabled = PGGetBool(@"sliderHaptic", YES);

    [self refresh];
}

- (void)rebuildNoiseViewIfNeeded {
    [_noiseView removeFromSuperview];
    _noiseView = nil;
    if (PGGetInt(@"backgroundStyle", 0) != 1) return;

    CGSize size = CGSizeMake(48, 48);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *noise = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGContextSetFillColorWithColor(cg, [UIColor clearColor].CGColor);
        CGContextFillRect(cg, CGRectMake(0, 0, size.width, size.height));
        for (NSInteger i = 0; i < 900; i++) {
            CGFloat x = arc4random_uniform((uint32_t)size.width);
            CGFloat y = arc4random_uniform((uint32_t)size.height);
            CGFloat alpha = 0.02 + (arc4random_uniform(10) / 100.0);
            CGContextSetFillColorWithColor(cg, [UIColor colorWithWhite:1.0 alpha:alpha].CGColor);
            CGContextFillRect(cg, CGRectMake(x, y, 1, 1));
        }
    }];
    _noiseView = [[UIImageView alloc] initWithImage:noise];
    _noiseView.frame = self.bounds;
    _noiseView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _noiseView.alpha = 0.55;
    _noiseView.layer.cornerRadius = self.layer.cornerRadius;
    _noiseView.layer.masksToBounds = YES;
    [self insertSubview:_noiseView aboveSubview:_effectView];
}

- (void)startTimer {
    __weak PGCardView *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        PGCardView *strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf refresh];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    if (!CGRectEqualToRect(frame, CGRectZero)) {
        CGFloat radius = PGGetFloat(@"cornerRadius", 24.0);
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
        if (_borderLayer) {
            _borderLayer.frame = self.bounds;
            _borderLayer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
        }
        if (_effectView) _effectView.frame = self.bounds;
    }
    [self setNeedsLayout];
}

- (void)refresh {
    _timeLabel.text = PGTimeString();

    NSInteger percent = PGBatteryPercent();
    BOOL charging = PGBatteryIsCharging();
    NSString *batteryText = percent >= 0 ? [NSString stringWithFormat:@"%@%%", @(percent)] : @"--";
    NSMutableAttributedString *battery = [[NSMutableAttributedString alloc] initWithString:batteryText
        attributes:@{NSFontAttributeName : PGFont(13), NSForegroundColorAttributeName : PGTextColor(0.92)}];
    if (charging) {
        NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
        UIImage *bolt = PGSymbol(@"bolt.fill", 10, UIImageSymbolWeightBold);
        if (bolt) {
            attachment.image = [bolt imageWithTintColor:[UIColor colorWithRed:0.45 green:0.95 blue:0.55 alpha:1.0]];
            attachment.bounds = CGRectMake(0, -2, 11, 11);
        }
        [battery appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    }
    _batteryLabel.attributedText = battery;

    CGFloat temperature = PGBatteryTemperature();
    if (isnan(temperature)) {
        _tempLabel.text = @"--°";
    } else {
        _tempLabel.text = [NSString stringWithFormat:@"%.1f°", temperature];
        if (temperature >= 42.0) _tempLabel.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.4 alpha:1.0];
        else if (temperature >= 38.0) _tempLabel.textColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.35 alpha:1.0];
        else _tempLabel.textColor = PGTextColor(0.92);
    }

    CGFloat cpu = PGCPUPercent();
    _cpuLabel.text = [NSString stringWithFormat:@"CPU %.0f%%", cpu];
    if (cpu >= 80.0) _cpuLabel.textColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.4 alpha:1.0];
    else if (cpu >= 60.0) _cpuLabel.textColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.4 alpha:1.0];
    else _cpuLabel.textColor = PGTextColor(0.92);

    [self refreshMusic];

    [self setNeedsLayout];
}

- (void)refreshMusic {
    NSDictionary *info = PGNowPlayingInfo();
    NSString *title = info[PGMRTitleKey];
    NSString *artist = info[PGMRArtistKey];
    NSString *album = info[PGMRAlbumKey];

    _hasMusic = (title.length > 0);
    if (!_hasMusic) {
        _titleLabel.text = @"未播放";
        _subtitleLabel.text = @"打开音乐 App 后显示歌曲信息";
        _lyricsLabel.text = nil;
        _currentArtwork = nil;
        _artView.image = PGSymbol(@"music.note", 26, UIImageSymbolWeightRegular);
        _artView.contentMode = UIViewContentModeCenter;
        _artView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        _isPlaying = NO;
        _duration = 0;
        _elapsed = 0;
        [_playButton setImage:PGSymbol(@"play.fill", 17, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
        [self updateProgressLabels];
        [self setNeedsLayout];
        return;
    }
    _artView.contentMode = _currentArtwork ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter;

    id durationValue = info[PGMRDurationKey];
    _duration = [durationValue respondsToSelector:@selector(doubleValue)] ? [durationValue doubleValue] : 0;
    if (!self.scrubbing) {
        id elapsedValue = info[PGMRElapsedKey];
        if ([elapsedValue respondsToSelector:@selector(doubleValue)]) {
            _elapsed = [elapsedValue doubleValue];
        } else if (_playbackRate > 0 && _elapsed < _duration) {
            _elapsed = MIN(_duration, _elapsed + 1.0);
        }
    }
    id rateValue = info[PGMRRateKey];
    _playbackRate = [rateValue respondsToSelector:@selector(doubleValue)] ? [rateValue doubleValue] : (_duration > 0 ? 1.0 : 0.0);
    _isPlaying = _playbackRate > 0.01;
    [_playButton setImage:PGSymbol(_isPlaying ? @"pause.fill" : @"play.fill", 17, UIImageSymbolWeightSemibold)
                 forState:UIControlStateNormal];
    if (!_artView.image) {
        _artView.image = PGSymbol(@"music.note", 26, UIImageSymbolWeightRegular);
        _artView.contentMode = UIViewContentModeCenter;
    }

    _titleLabel.text = title;
    if (album.length > 0 && artist.length > 0) {
        _subtitleLabel.text = [NSString stringWithFormat:@"%@ · %@", artist, album];
    } else if (artist.length > 0) {
        _subtitleLabel.text = artist;
    } else {
        _subtitleLabel.text = album;
    }

    id artworkData = info[PGMRArtworkKey];
    if ([artworkData isKindOfClass:[NSData class]]) {
        UIImage *image = [UIImage imageWithData:artworkData];
        if (image && image != _currentArtwork) {
            _currentArtwork = image;
            _artView.image = image;
        }
    } else if (!_currentArtwork) {
        _currentArtwork = nil;
        _artView.image = nil;
    }

    if (![_lastTitle isEqualToString:title] || ![_lastArtist isEqualToString:artist]) {
        _lastTitle = title;
        _lastArtist = artist;
        [_lyrics updateWithTitle:title artist:artist];
    }

    if (self.expanded && PGGetBool(@"showLyrics", YES)) {
        NSString *line = [_lyrics lineAtTime:_elapsed];
        _lyricsLabel.text = line;
    } else {
        _lyricsLabel.text = nil;
    }

    [self updateProgressLabels];
}

- (void)updateProgressLabels {
    _progressBar.progress = _duration > 0 ? (_elapsed / _duration) : 0;
    _elapsedLabel.text = PGClockString(_elapsed);
    _durationLabel.text = PGClockString(_duration);
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (!PGGetBool(@"longPressControls", YES)) return;
    CGPoint point = [gesture locationInView:self];
    if (CGRectContainsPoint(_progressBar.frame, point)) return;
    if (CGRectContainsPoint(_playButton.frame, point) || CGRectContainsPoint(_previousButton.frame, point) || CGRectContainsPoint(_nextButton.frame, point)) return;
    self.expanded = !self.expanded;
    PGHapticLight();
    [self setNeedsLayout];
    [self layoutIfNeeded];
    if (self.onExpandedChange) self.onExpandedChange();
}

- (void)collapseTapped {
    if (self.onCollapse) self.onCollapse();
}

- (void)previousTapped {
    PGSendMediaCommand(5, nil);
    [self performSelector:@selector(refresh) withObject:nil afterDelay:0.4];
}

- (void)playPauseTapped {
    PGSendMediaCommand(2, nil);
    [self performSelector:@selector(refresh) withObject:nil afterDelay:0.25];
}

- (void)nextTapped {
    PGSendMediaCommand(4, nil);
    [self performSelector:@selector(refresh) withObject:nil afterDelay:0.4];
}

- (void)flashIn {
    self.alpha = 0.0;
    self.transform = CGAffineTransformMakeTranslation(0, -12);
    [UIView animateWithDuration:0.42 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.6 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)collapseAnimated:(BOOL)animated completion:(void (^)(void))completion {
    void (^finish)(void) = ^{
        [self removeFromSuperview];
        if (completion) completion();
    };
    if (!animated) { finish(); return; }
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self.alpha = 0.0;
        self.transform = CGAffineTransformMakeTranslation(0, -18);
    } completion:^(BOOL finished) {
        finish();
    }];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat pad = 14.0;

    _effectView.frame = self.bounds;
    _borderLayer.frame = self.bounds;
    if (_noiseView) _noiseView.frame = self.bounds;

    _handleView.frame = CGRectMake((width - 38.0) / 2.0, 7.0, 38.0, 4.0);
    _collapseButton.frame = CGRectMake(width - 34.0, 6.0, 26.0, 26.0);

    CGFloat contentTop = 16.0;
    CGFloat timeHeight = 36.0;
    _timeLabel.frame = CGRectMake(pad, contentTop, MIN(150.0, width * 0.42), timeHeight);

    CGFloat statsY = contentTop + 10.0;
    CGFloat statsHeight = 16.0;
    CGFloat rightEdge = width - pad;
    NSArray<UILabel *> *statLabels = @[_cpuLabel, _tempLabel, _batteryLabel];
    for (UILabel *label in statLabels) {
        CGSize fit = [label sizeThatFits:CGSizeMake(200.0, 20.0)];
        label.frame = CGRectMake(rightEdge - fit.width, statsY, fit.width, statsHeight);
        rightEdge -= fit.width + 9.0;
    }

    CGFloat separatorY = contentTop + 44.0;
    if (!_separatorLayer) {
        _separatorLayer = [CALayer layer];
        _separatorLayer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        [self.layer addSublayer:_separatorLayer];
    }
    _separatorLayer.frame = CGRectMake(pad, separatorY, width - pad * 2.0, 0.5);

    CGFloat musicTop = separatorY + 12.0;

    BOOL allowControls = (_hasMusic && height >= 190.0);
    BOOL showControls = allowControls && (!PGGetBool(@"longPressControls", YES) || self.expanded);
    _progressBar.hidden = !showControls;
    _elapsedLabel.hidden = !showControls;
    _durationLabel.hidden = !showControls;
    _previousButton.hidden = !showControls;
    _playButton.hidden = !showControls;
    _nextButton.hidden = !showControls;

    _emptyLabel.hidden = _hasMusic;

    CGFloat controlsHeight = showControls ? 40.0 : 0.0;
    CGFloat progressHeight = showControls ? 30.0 : 0.0;
    CGFloat controlsTop = height - pad - controlsHeight;
    CGFloat progressTop = controlsTop - progressHeight;

    if (!showControls) {
        CGFloat compactArt = MIN(60.0, MAX(38.0, height - musicTop - pad));
        compactArt = MIN(compactArt, width - pad * 2.0);
        _artView.frame = CGRectMake(pad, musicTop + 2.0, compactArt, compactArt);
        _artView.layer.cornerRadius = MIN(12.0, compactArt / 4.0);
        CGFloat compactTextX = pad + compactArt + 12.0;
        CGFloat compactTextWidth = width - compactTextX - pad;
        _titleLabel.frame = CGRectMake(compactTextX, musicTop + 3.0, compactTextWidth, 20.0);
        _subtitleLabel.frame = CGRectMake(compactTextX, musicTop + 25.0, compactTextWidth, 16.0);
        _lyricsLabel.frame = CGRectMake(compactTextX, musicTop + 45.0, compactTextWidth, MAX(0.0, height - pad - (musicTop + 45.0)));
        _emptyLabel.frame = CGRectZero;
        return;
    }

    CGFloat artSize = 56.0;
    CGFloat availableHeight = progressTop - musicTop - 10.0;
    if (availableHeight < artSize) artSize = MAX(38.0, availableHeight);
    artSize = MIN(artSize, width - pad * 2.0);
    _artView.frame = CGRectMake(pad, musicTop + 2.0, artSize, artSize);
    _artView.layer.cornerRadius = MIN(12.0, artSize / 4.0);

    CGFloat textX = pad + artSize + 12.0;
    CGFloat textWidth = width - textX - pad;
    _titleLabel.frame = CGRectMake(textX, musicTop + 1.0, textWidth, 20.0);
    _subtitleLabel.frame = CGRectMake(textX, musicTop + 23.0, textWidth, 16.0);
    _lyricsLabel.frame = CGRectMake(textX, musicTop + 43.0, textWidth, MAX(0.0, progressTop - musicTop - 46.0));

    _progressBar.frame = CGRectMake(pad + 2.0, progressTop + 2.0, width - pad * 2.0 - 4.0, 26.0);
    _elapsedLabel.frame = CGRectMake(pad, progressTop + 2.0, 60.0, 12.0);
    _elapsedLabel.hidden = YES;
    _durationLabel.frame = CGRectMake(width - pad - 60.0, progressTop + 2.0, 60.0, 12.0);
    _durationLabel.hidden = YES;

    CGFloat buttonSize = 34.0;
    CGFloat spacing = 18.0;
    CGFloat totalWidth = buttonSize * 3.0 + spacing * 2.0;
    CGFloat startX = (width - totalWidth) / 2.0;
    CGFloat buttonY = controlsTop + 3.0;
    _previousButton.frame = CGRectMake(startX, buttonY, buttonSize, buttonSize);
    _playButton.frame = CGRectMake(startX + buttonSize + spacing, buttonY, buttonSize, buttonSize);
    _nextButton.frame = CGRectMake(startX + (buttonSize + spacing) * 2.0, buttonY, buttonSize, buttonSize);

    _emptyLabel.frame = CGRectMake(pad, musicTop, width - pad * 2.0, MAX(0.0, controlsTop - musicTop));
}

@end

#pragma mark - 卡片管理

@interface PGCardManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, strong) PGCardView *card;
@property (nonatomic, weak) UIView *anchorTongue;
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, assign) BOOL manuallyCollapsed;
@property (nonatomic, assign) BOOL hiddenForNotificationCenter;
- (void)tongueWillPresent:(UIView *)tongue;
- (void)tongueDidPresent:(UIView *)tongue;
- (void)hideCardAnimated:(BOOL)animated manual:(BOOL)manual;
- (void)applyPreferences;
@end

@implementation PGCardManager

+ (instancetype)sharedManager {
    static PGCardManager *manager = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = [[PGCardManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self startMonitorTimer];
        [self registerForNotifications];
    }
    return self;
}

- (void)registerForNotifications {
    if (!PGMRInfoChangedNote) return;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaInfoChanged)
                                             name:PGMRInfoChangedNote
                                           object:nil];
}

- (void)startMonitorTimer {
    __weak PGCardManager *weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        PGCardManager *strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf monitor];
    }];
}

- (void)mediaInfoChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.card refresh];
    });
}

- (void)monitor {
    if (!self.card) return;
    if (!self.card.superview) {
        if (self.anchorTongue && !self.manuallyCollapsed) {
            [self attachCardToHostForTongue:self.anchorTongue];
        }
        return;
    }

    UIWindow *hostWindow = self.card.window;
    if (hostWindow && hostWindow != self.overlayWindow && (hostWindow.hidden || hostWindow.alpha < 0.01)) {
        [self.card removeFromSuperview];
        UIWindow *overlay = [self overlayWindowForTongue:self.anchorTongue];
        [overlay addSubview:self.card];
        [self layoutCardInHost:overlay tongue:self.anchorTongue];
        return;
    }

    BOOL ncVisible = [self notificationCenterVisible];
    if (ncVisible && !self.card.hidden) {
        self.card.hidden = YES;
        self.hiddenForNotificationCenter = YES;
    } else if (!ncVisible && self.hiddenForNotificationCenter) {
        self.card.hidden = NO;
        self.hiddenForNotificationCenter = NO;
    }
}

- (BOOL)notificationCenterVisible {
    Class cls = NSClassFromString(@"SBUIController");
    if (cls) {
        id controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
        if (controller) {
            NSArray<NSString *> *names = @[@"isNotificationCenterVisible", @"_isNotificationCenterVisible",
                                           @"notificationCenterIsVisible", @"_notificationCenterIsVisible",
                                           @"isNotificationCenterShowing", @"_isNotificationCenterShowing"];
            for (NSString *name in names) {
                SEL selector = NSSelectorFromString(name);
                if (selector && [controller respondsToSelector:selector]) {
                    return ((BOOL (*)(id, SEL))objc_msgSend)(controller, selector);
                }
            }
        }
    }
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        NSString *className = NSStringFromClass([window class]).lowercaseString;
        if ([className containsString:@"notification"] && !window.hidden && window.alpha > 0.01) {
            return YES;
        }
    }
    return NO;
}

- (void)applyPreferences {
    if (!self.card) return;
    [self.card applyPreferences];
    if (self.card.superview && self.anchorTongue) {
        [self layoutCardInHost:self.card.superview tongue:self.anchorTongue];
    }
}

- (void)tongueWillPresent:(UIView *)tongue {
    NSLog(@"[GrabberCard] grabber will present: %@ (window=%@, bounds=%@)",
          tongue, NSStringFromClass([tongue.window class]),
          NSStringFromCGRect(tongue.window.bounds));
    if (!PGGetBool(@"enabled", YES)) return;
    self.anchorTongue = tongue;
    self.manuallyCollapsed = NO;
    [self showCardForTongue:tongue];
}

- (void)tongueDidPresent:(UIView *)tongue {
    self.anchorTongue = tongue;
    if (self.card.superview) {
        [self layoutCardInHost:self.card.superview tongue:tongue];
    }
}

- (void)showCardForTongue:(UIView *)tongue {
    if (!PGGetBool(@"enabled", YES)) return;

    BOOL shouldAnimate = NO;
    if (!self.card) {
        self.card = [[PGCardView alloc] initWithFrame:CGRectZero];
        __weak PGCardManager *weakManager = self;
        self.card.onCollapse = ^{
            [weakManager hideCardAnimated:YES manual:YES];
        };
        self.card.onExpandedChange = ^{
            [weakManager layoutCardInHost:weakManager.card.superview tongue:weakManager.anchorTongue];
        };
        shouldAnimate = YES;
    }

    [self.card applyPreferences];
    [self.card refresh];
    [self attachCardToHostForTongue:tongue];

    if (shouldAnimate) {
        [self.card flashIn];
    } else if (self.card.hidden) {
        self.card.hidden = NO;
    }

    if (PGGetBool(@"presentHaptic", YES)) {
        PGHapticLight();
    }
}

- (void)attachCardToHostForTongue:(UIView *)tongue {
    UIView *host = nil;
    if (tongue.window && CGRectGetHeight(tongue.window.bounds) > 300.0) {
        host = tongue.window;
    } else if (tongue.superview && CGRectGetHeight(tongue.superview.bounds) > 300.0) {
        host = tongue.superview;
    }
    if (!host) host = [self overlayWindowForTongue:tongue];
    if (!host) return;

    if (self.card.superview != host) {
        [self.card removeFromSuperview];
        [host addSubview:self.card];
    }
    [host bringSubviewToFront:self.card];

    [self layoutCardInHost:host tongue:tongue];
    self.card.hidden = NO;
}

- (UIWindow *)overlayWindowForTongue:(UIView *)tongue {
    if (!self.overlayWindow) {
        CGRect frame = [UIScreen mainScreen].bounds;
        self.overlayWindow = [[UIWindow alloc] initWithFrame:frame];
        self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 1.0;
        self.overlayWindow.backgroundColor = [UIColor clearColor];
        self.overlayWindow.userInteractionEnabled = YES;
    }
    self.overlayWindow.hidden = NO;
    return self.overlayWindow;
}

- (void)layoutCardInHost:(UIView *)host tongue:(UIView *)tongue {
    CGFloat scale = MIN(1.3, MAX(0.8, PGGetFloat(@"cardScale", 1.0)));
    CGFloat baseWidth = MIN(430.0, MAX(240.0, PGGetFloat(@"cardWidth", 356.0)));
    CGFloat baseHeight = MIN(440.0, MAX(150.0, PGGetFloat(@"cardHeight", 246.0)));

    BOOL expanded = (self.card.expanded && PGGetBool(@"longPressControls", YES));
    CGFloat minimumHeight = expanded ? 236.0 : 150.0;
    CGFloat cardWidth = MIN(baseWidth * scale, CGRectGetWidth(host.bounds) - 24.0);
    CGFloat cardHeight = MIN(MAX(baseHeight * scale, minimumHeight), CGRectGetHeight(host.bounds) - 120.0);
    cardWidth = MAX(200.0, cardWidth);
    cardHeight = MAX(120.0, cardHeight);

    CGRect anchor = CGRectZero;
    if (tongue && tongue.window) {
        anchor = [tongue convertRect:tongue.bounds toView:host];
    }
    if (CGRectGetHeight(anchor) < 1.0) {
        CGFloat safeTop = host.safeAreaInsets.top;
        anchor = CGRectMake(CGRectGetMidX(host.bounds) - 20.0, safeTop, 40.0, 20.0);
    }

    CGFloat x = CGRectGetMidX(anchor) - cardWidth / 2.0;
    x = MIN(MAX(12.0, x), CGRectGetWidth(host.bounds) - cardWidth - 12.0);
    CGFloat y = CGRectGetMaxY(anchor) + 8.0;
    if (y + cardHeight > CGRectGetHeight(host.bounds) - 8.0) {
        y = MAX(8.0, CGRectGetMinY(anchor) - cardHeight - 8.0);
    }
    if (y < 0) y = 0;

    self.card.frame = CGRectMake(x, y, cardWidth, cardHeight);
    [self.card setNeedsLayout];
}

- (void)hideCardAnimated:(BOOL)animated manual:(BOOL)manual {
    if (!self.card) return;
    if (manual) self.manuallyCollapsed = YES;
    PGCardView *card = self.card;
    self.card = nil;
    [card collapseAnimated:animated completion:nil];
}

@end

#pragma mark - Hooks

static void (*gOrigWillPresent)(id, SEL);
static void (*gOrigDidPresent)(id, SEL);
static void (*gOrigWillDismiss)(id, SEL);
static void (*gOrigDidDismiss)(id, SEL);
static void (*gOrigFrontDisplayDidChange)(id, SEL, id);

static void PGHookWillPresent(id self, SEL _cmd) {
    if (gOrigWillPresent) gOrigWillPresent(self, _cmd);
    [[PGCardManager sharedManager] tongueWillPresent:(UIView *)self];
}

static void PGHookDidPresent(id self, SEL _cmd) {
    if (gOrigDidPresent) gOrigDidPresent(self, _cmd);
    [[PGCardManager sharedManager] tongueDidPresent:(UIView *)self];
}

static void PGHookWillDismiss(id self, SEL _cmd) {
    if (gOrigWillDismiss) gOrigWillDismiss(self, _cmd);
}

static void PGHookDidDismiss(id self, SEL _cmd) {
    if (gOrigDidDismiss) gOrigDidDismiss(self, _cmd);
}

static void PGHookFrontDisplayDidChange(id self, SEL _cmd, id arg) {
    if (gOrigFrontDisplayDidChange) gOrigFrontDisplayDidChange(self, _cmd, arg);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PGCardManager sharedManager] hideCardAnimated:YES manual:NO];
    });
}

static void PGInstallHook(Class cls, SEL selector, IMP implementation, IMP *original);

static void PGInstallHookAny(Class cls, NSArray<NSString *> *names, IMP implementation, IMP *original) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if (!selector) continue;
        if (class_getInstanceMethod(cls, selector)) {
            PGInstallHook(cls, selector, implementation, original);
            return;
        }
    }
}

static void PGInstallHook(Class cls, SEL selector, IMP implementation, IMP *original) {
    if (!cls || !selector || !implementation) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, implementation, method_getTypeEncoding(method))) {
        method_setImplementation(method, implementation);
    }
}

#pragma mark - 通知

static void PGPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PGCardManager sharedManager] applyPreferences];
    });
}

static void PGLockStateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PGCardManager sharedManager] hideCardAnimated:NO manual:NO];
    });
}

#pragma mark - 启动

static void PGInstallHooks(void) {
    Class tongueClass = NSClassFromString(@"SBGrabberTongue");
    if (!tongueClass) {
        NSLog(@"[GrabberCard] SBGrabberTongue not found");
        return;
    }

    PGInstallHookAny(tongueClass, @[@"_willPresent", @"willPresent", @"_willPresent:"], (IMP)PGHookWillPresent, (IMP *)&gOrigWillPresent);
    PGInstallHookAny(tongueClass, @[@"_didPresent", @"didPresent", @"_didPresent:"], (IMP)PGHookDidPresent, (IMP *)&gOrigDidPresent);
    PGInstallHookAny(tongueClass, @[@"_willDismiss", @"willDismiss", @"_willDismiss:"], (IMP)PGHookWillDismiss, (IMP *)&gOrigWillDismiss);
    PGInstallHookAny(tongueClass, @[@"_didDismiss", @"didDismiss", @"_didDismiss:"], (IMP)PGHookDidDismiss, (IMP *)&gOrigDidDismiss);

    Class springBoardClass = NSClassFromString(@"SpringBoard");
    if (springBoardClass) {
        PGInstallHook(springBoardClass, NSSelectorFromString(@"frontDisplayDidChange:"), (IMP)PGHookFrontDisplayDidChange, (IMP *)&gOrigFrontDisplayDidChange);
    }
}

__attribute__((constructor)) static void GrabberCardInitialize(void) {
    @autoreleasepool {
        PGLoadMediaRemote();

        if (PGMRRegisterFunc) {
            PGMRRegisterFunc(dispatch_get_main_queue());
        }

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PGPrefsChangedCallback,
                                        CFSTR("com.grabbercard.prefs.changed"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        PGLockStateChanged,
                                        CFSTR("com.apple.springboard.lockstate"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        if (NSClassFromString(@"SBGrabberTongue")) {
            PGInstallHooks();
            NSLog(@"[GrabberCard] hooks installed");
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                PGInstallHooks();
            });
        }
    }
}
