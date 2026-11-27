//
//  Tweak.m
//  GrabberCard — 游戏内下拉显示的时间 / 电量 / 温度 / CPU / 音乐控制卡片
//
//  目标设备: iPhone 14 Pro Max / iOS 16.3.1 / Dopamine RootHide
//
//  1.1-63 修复清单
//  - 方向：卡片改挂到与原生面板同一个 UIWindowScene 的独立窗口，带 rootViewController
//    跟随设备旋转；横屏时按“离哪条边最近”决定卡片放在锚点哪一侧，不再固定画在下方。
//  - 关闭：右上角常驻 × 按钮（44pt 热区），顶部小横条可点按收起/展开；关闭后卡片完全移除，
//    下次下拉重新出现。
//  - 进度条：拖动过程立即重绘（不再等下一帧布局），本地按播放速率推算进度，
//    seek 后 1.2 秒内忽略播放器回传的旧进度，避免“拉完又弹回去”。
//  - 触摸：覆盖窗口与卡片容器都只让卡片区域吃触摸，其余全部穿透给游戏。
//  - 性能：偏好读取加内存缓存；封面按数据比对避免每秒重新解码；封面/指标降频刷新。
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

static NSTimeInterval PGNow(void) {
    return [NSDate timeIntervalSinceReferenceDate];
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

@implementation PGLyricsProvider {
    NSURLSession *_session;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lines = @[];
    }
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

- (NSURLSession *)session {
    if (!_session) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 7.0;
        config.timeoutIntervalForResource = 12.0;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return _session;
}

- (void)cancelRequests {
    [_session invalidateAndCancel];
    _session = nil;
}

- (void)reset {
    [self cancelRequests];
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

    [self cancelRequests];
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
    NSURLSession *session = [self session];

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

static NSDictionary *PGPowerSourceDescription(void);

static NSInteger PGBatteryPercent(void) {
    Class cls = NSClassFromString(@"SBUIController");
    if (cls) {
        id controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
        if (controller && [controller respondsToSelector:@selector(batteryCapacityAsPercentage)]) {
            NSInteger value = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(batteryCapacityAsPercentage));
            if (value > 0 && value <= 100) return value;
        }
    }
    // 兜底：直接问 IOKit 电源信息
    NSDictionary *source = PGPowerSourceDescription();
    NSNumber *current = source[@"Current Capacity"];
    NSNumber *max = source[@"Max Capacity"];
    if ([current respondsToSelector:@selector(doubleValue)] && [max respondsToSelector:@selector(doubleValue)]) {
        CGFloat maxValue = [max doubleValue];
        if (maxValue > 0) {
            NSInteger value = (NSInteger)round([current doubleValue] / maxValue * 100.0);
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
    NSDictionary *source = PGPowerSourceDescription();
    id charging = source[@"Is Charging"];
    if ([charging respondsToSelector:@selector(boolValue)]) return [charging boolValue];
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

// 纵向热区扩到 44pt，横向扩 8pt：手指不用精确戳在 4pt 细线上。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -8.0, -9.0), point);
}

- (void)setProgress:(CGFloat)progress {
    progress = MIN(1.0, MAX(0.0, progress));
    if (fabs(progress - _progress) < 0.000001) { _progress = progress; return; }
    _progress = progress;
    // 立即重绘：拖动时不等 layoutSubviews，进度条跟着手指走。
    [self updateFrames];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateFrames];
}

- (void)updateFrames {
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width <= 0 || height <= 0) return;

    CGFloat trackHeight = 4.0;
    CGFloat centerY = height / 2.0;
    _trackView.frame = CGRectMake(0, centerY - trackHeight / 2.0, width, trackHeight);
    _fillView.frame = CGRectMake(0, centerY - trackHeight / 2.0, MAX(0, width * _progress), trackHeight);
    CGFloat knobSize = 13.0;
    _knobView.frame = CGRectMake(MAX(0, MIN(width - knobSize, width * _progress - knobSize / 2.0)), centerY - knobSize / 2.0, knobSize, knobSize);
    _knobView.layer.cornerRadius = knobSize / 2.0;
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self updateProgressWithTouch:touch];
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

    if (fabs(progress - _progress) < 0.0002) return;
    self.progress = progress;

    if (self.hapticEnabled) {
        NSInteger step = (NSInteger)floor(progress * 40.0);
        if (step != (NSInteger)_lastHapticStep) {
            _lastHapticStep = step;
            PGHapticLight();
        }
    }

    if (self.onScrub) self.onScrub(progress);
}

@end

#pragma mark - 关闭按钮

@interface PGCloseButton : UIButton
@end

@implementation PGCloseButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -8.0, -8.0), point);
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
- (void)refreshMetrics;
- (void)seekToProgress:(CGFloat)progress;
- (void)flashIn;
- (void)collapseAnimated:(BOOL)animated completion:(void (^)(void))completion;
@end

@implementation PGCardView {
    UIVisualEffectView *_effectView;
    UIImageView *_noiseView;
    CALayer *_borderLayer;
    CALayer *_separatorLayer;

    UIButton *_handleButton;
    UIView *_handleBar;
    PGCloseButton *_closeButton;

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
    NSData *_lastArtworkData;
    NSString *_lastTitle;
    NSString *_lastArtist;

    NSTimeInterval _lastSyncTime;
    NSTimeInterval _lastSyncElapsed;
    NSTimeInterval _seekHoldUntil;
    NSInteger _metricTick;
    NSInteger _lastStyleIndex;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _lyrics = [[PGLyricsProvider alloc] init];
        _playbackRate = 1.0;
        _lastSyncTime = PGNow();
        _metricTick = 3;
        [self buildSubviews];
        [self applyPreferences];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [self startTimerIfNeeded];
    } else {
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)buildSubviews {
    self.backgroundColor = [UIColor clearColor];
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 12.0;
    self.layer.shadowOffset = CGSizeMake(0, 6);
    self.clipsToBounds = NO;

    _handleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _handleButton.backgroundColor = [UIColor clearColor];
    [_handleButton addTarget:self action:@selector(handleTapped) forControlEvents:UIControlEventTouchUpInside];
    _handleButton.accessibilityLabel = @"展开或收起卡片";
    [self addSubview:_handleButton];

    _handleBar = [[UIView alloc] init];
    _handleBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.38];
    _handleBar.layer.cornerRadius = 2.0;
    _handleBar.userInteractionEnabled = NO;
    [_handleButton addSubview:_handleBar];

    _closeButton = [PGCloseButton buttonWithType:UIButtonTypeCustom];
    [_closeButton setImage:PGSymbol(@"xmark", 14, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    _closeButton.tintColor = PGTextColor(0.9);
    _closeButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.30];
    _closeButton.layer.cornerRadius = 16.0;
    _closeButton.layer.borderWidth = 0.5;
    _closeButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    _closeButton.accessibilityLabel = @"关闭卡片";
    [_closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_closeButton];

    _timeLabel = [[UILabel alloc] init];
    _timeLabel.textColor = PGTextColor(1.0);
    _timeLabel.backgroundColor = [UIColor clearColor];
    _timeLabel.font = PGFont(28);
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
    _artView.contentMode = UIViewContentModeCenter;
    _artView.clipsToBounds = YES;
    _artView.tintColor = PGTextColor(0.55);
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
        [strongSelf layoutIfNeeded];
    };
    _progressBar.onSeek = ^(CGFloat progress) {
        PGCardView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf seekToProgress:progress];
    };
    [self addSubview:_progressBar];

    _elapsedLabel = [[UILabel alloc] init];
    _elapsedLabel.textColor = PGTextColor(0.60);
    _elapsedLabel.backgroundColor = [UIColor clearColor];
    _elapsedLabel.font = PGFont(10);
    [self addSubview:_elapsedLabel];

    _durationLabel = [[UILabel alloc] init];
    _durationLabel.textColor = PGTextColor(0.60);
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
    longPress.allowableMovement = 24.0;
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
    CGFloat radius = MIN(PGGetFloat(@"cornerRadius", 24.0), CGRectGetHeight(self.bounds) / 2.0);
    if (radius <= 0) radius = PGGetFloat(@"cornerRadius", 24.0);
    self.layer.cornerRadius = radius;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;

    NSInteger styleIndex = PGGetInt(@"backgroundStyle", 0);
    BOOL rebuildEffect = (!_effectView || styleIndex != _lastStyleIndex);
    if (rebuildEffect) {
        [_effectView removeFromSuperview];
        _effectView = nil;

        UIBlurEffectStyle style = UIBlurEffectStyleSystemMaterial;
        switch (styleIndex) {
            case 1: style = UIBlurEffectStyleSystemUltraThinMaterial; break;
            case 2: style = UIBlurEffectStyleSystemThickMaterial; break;
            default: style = UIBlurEffectStyleSystemMaterial; break;
        }
        _effectView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
        _effectView.frame = self.bounds;
        _effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _effectView.layer.masksToBounds = YES;
        [self insertSubview:_effectView atIndex:0];
        _lastStyleIndex = styleIndex;
        [self rebuildNoiseViewIfNeeded];
    }
    // 透明度/圆角这类滑杆变化只更新属性，不重建毛玻璃视图。
    _effectView.layer.cornerRadius = radius;
    _effectView.alpha = PGGetFloat(@"opacity", 0.92);

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

    _timeLabel.font = PGFont(28);
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

- (void)startTimerIfNeeded {
    if (_timer) return;
    __weak PGCardView *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        PGCardView *strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf refresh];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    if (!CGRectEqualToRect(frame, CGRectZero)) {
        CGFloat radius = MIN(PGGetFloat(@"cornerRadius", 24.0), CGRectGetHeight(self.bounds) / 2.0);
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
        if (_borderLayer) {
            _borderLayer.frame = self.bounds;
            _borderLayer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
        }
        if (_effectView) _effectView.frame = self.bounds;
    }
    [self setNeedsLayout];
}

- (void)setExpanded:(BOOL)expanded {
    if (_expanded == expanded) return;
    _expanded = expanded;
    [self setNeedsLayout];
}

- (void)refresh {
    _timeLabel.text = PGTimeString();

    // 电量/温度/CPU 每 2 秒采样一次就够，避免每 0.5 秒做一次 IOKit / host_info。
    _metricTick++;
    if (_metricTick >= 4) {
        _metricTick = 0;
        [self refreshMetrics];
    }

    [self refreshMusic];
    [self setNeedsLayout];
}

- (void)refreshMetrics {
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
}

- (void)refreshMusic {
    NSDictionary *info = PGNowPlayingInfo();
    NSString *title = info[PGMRTitleKey];
    NSString *artist = info[PGMRArtistKey];
    NSString *album = info[PGMRAlbumKey];

    NSTimeInterval now = PGNow();
    _hasMusic = (title.length > 0);
    if (!_hasMusic) {
        _titleLabel.text = @"未播放";
        _subtitleLabel.text = @"打开音乐 App 后显示歌曲信息";
        _lyricsLabel.text = nil;
        _currentArtwork = nil;
        _lastArtworkData = nil;
        _lastTitle = nil;
        _lastArtist = nil;
        _artView.image = PGSymbol(@"music.note", 26, UIImageSymbolWeightRegular);
        _artView.contentMode = UIViewContentModeCenter;
        _artView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        _isPlaying = NO;
        _duration = 0;
        _elapsed = 0;
        _playbackRate = 0;
        _lastSyncElapsed = 0;
        _lastSyncTime = now;
        _seekHoldUntil = 0;
        [_playButton setImage:PGSymbol(@"play.fill", 17, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
        [self updateProgressLabels];
        [self setNeedsLayout];
        return;
    }

    BOOL trackChanged = ![_lastTitle isEqualToString:title] || ![_lastArtist isEqualToString:artist];

    id durationValue = info[PGMRDurationKey];
    NSTimeInterval reportedDuration = [durationValue respondsToSelector:@selector(doubleValue)] ? [durationValue doubleValue] : 0;
    if (reportedDuration > 0) _duration = reportedDuration;

    id rateValue = info[PGMRRateKey];
    _playbackRate = [rateValue respondsToSelector:@selector(doubleValue)] ? [rateValue doubleValue] : (_duration > 0 ? 1.0 : 0.0);
    _isPlaying = _playbackRate > 0.01;

    id elapsedValue = info[PGMRElapsedKey];
    NSTimeInterval reportedElapsed = -1;
    if ([elapsedValue respondsToSelector:@selector(doubleValue)]) {
        reportedElapsed = [elapsedValue doubleValue];
        if (reportedElapsed < 0) reportedElapsed = -1;
    }

    if (trackChanged || reportedElapsed < 0) {
        // 换歌或播放器不给进度：以当前值重新对齐。
        _lastSyncElapsed = MAX(0.0, reportedElapsed);
        _lastSyncTime = now;
        _seekHoldUntil = 0;
    } else if (!self.scrubbing && now >= _seekHoldUntil) {
        // 播放器回传的进度通常只在切歌/暂停时更新，其余时间按速率本地推算。
        NSTimeInterval predicted = _lastSyncElapsed + (now - _lastSyncTime) * MAX(0.0, _playbackRate);
        if (fabs(reportedElapsed - predicted) > 1.5) {
            _lastSyncElapsed = reportedElapsed;
            _lastSyncTime = now;
        }
    }

    if (!self.scrubbing) {
        NSTimeInterval predicted = _lastSyncElapsed + (now - _lastSyncTime) * MAX(0.0, _playbackRate);
        if (_duration > 0) predicted = MIN(predicted, _duration);
        _elapsed = MAX(0.0, predicted);
    }

    [_playButton setImage:PGSymbol(_isPlaying ? @"pause.fill" : @"play.fill", 17, UIImageSymbolWeightSemibold)
                 forState:UIControlStateNormal];

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
        // 只有封面数据真的变了才重新解码，否则每 0.5 秒解码一次大图非常吃 CPU。
        BOOL sameData = (artworkData == _lastArtworkData) ||
                        (_lastArtworkData.length == [(NSData *)artworkData length] &&
                         [(NSData *)artworkData isEqualToData:_lastArtworkData]);
        if (!sameData) {
            _lastArtworkData = artworkData;
            UIImage *image = [UIImage imageWithData:artworkData];
            if (image) {
                _currentArtwork = image;
                _artView.image = image;
                _artView.contentMode = UIViewContentModeScaleAspectFill;
            }
        }
    } else if (!_currentArtwork) {
        _artView.image = PGSymbol(@"music.note", 26, UIImageSymbolWeightRegular);
        _artView.contentMode = UIViewContentModeCenter;
    }

    if (trackChanged) {
        _lastTitle = title;
        _lastArtist = artist;
        [_lyrics updateWithTitle:title artist:artist];
    }

    if (self.expanded && PGGetBool(@"showLyrics", YES)) {
        _lyricsLabel.text = [_lyrics lineAtTime:_elapsed];
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

// 记住 seek 点，短时间内忽略播放器回传的旧进度，避免进度条弹回。
- (void)seekToProgress:(CGFloat)progress {
    NSTimeInterval now = PGNow();
    self.scrubbing = NO;
    self.elapsed = progress * _duration;
    _lastSyncElapsed = self.elapsed;
    _lastSyncTime = now;
    _seekHoldUntil = now + 1.2;
    NSDictionary *userInfo = @{PGMRElapsedKey ?: @"Elapsed Time" : @(self.elapsed)};
    PGSendMediaCommand(6, userInfo);
    [self updateProgressLabels];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (!PGGetBool(@"longPressControls", YES)) return;
    CGPoint point = [gesture locationInView:self];
    if (CGRectContainsPoint(_progressBar.frame, point)) return;
    // 横条和 × 自己会处理点按，长按不要再抢一次，否则松手会连着切换两次。
    if (CGRectContainsPoint(_handleButton.frame, point)) return;
    if (CGRectContainsPoint(_closeButton.frame, point)) return;
    if (CGRectContainsPoint(_playButton.frame, point) || CGRectContainsPoint(_previousButton.frame, point) || CGRectContainsPoint(_nextButton.frame, point)) return;
    [self toggleExpanded];
}

- (void)handleTapped {
    [self toggleExpanded];
}

- (void)toggleExpanded {
    self.expanded = !self.expanded;
    PGHapticLight();
    [self setNeedsLayout];
    [self layoutIfNeeded];
    if (self.onExpandedChange) self.onExpandedChange();
}

- (void)closeTapped {
    PGHapticLight();
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
    if (width <= 0 || height <= 0) return;

    CGFloat pad = 14.0;

    // 圆角始终夹到半高，收起态才不会出现"弧接不上"的方角。
    CGFloat radius = MIN(PGGetFloat(@"cornerRadius", 24.0), height / 2.0);
    self.layer.cornerRadius = radius;
    _effectView.layer.cornerRadius = radius;
    _borderLayer.cornerRadius = radius;
    if (_noiseView) _noiseView.layer.cornerRadius = radius;

    _effectView.frame = self.bounds;
    _borderLayer.frame = self.bounds;
    if (_noiseView) _noiseView.frame = self.bounds;

    // 顶部小横条：点一下切换展开/收起
    _handleButton.frame = CGRectMake((width - 64.0) / 2.0, 0.0, 64.0, 24.0);
    _handleBar.frame = CGRectMake((64.0 - 38.0) / 2.0, 10.0, 38.0, 4.0);

    // 右上角关闭按钮，永远在最上层
    _closeButton.frame = CGRectMake(width - pad - 32.0, 8.0, 32.0, 32.0);

    _timeLabel.frame = CGRectMake(pad, 10.0, MIN(150.0, width * 0.40), 34.0);

    CGFloat statsY = 22.0;
    CGFloat statsHeight = 16.0;
    CGFloat rightEdge = width - pad - 32.0 - 10.0;
    NSArray<UILabel *> *statLabels = @[_cpuLabel, _tempLabel, _batteryLabel];
    for (UILabel *label in statLabels) {
        CGSize fit = [label sizeThatFits:CGSizeMake(200.0, 20.0)];
        label.frame = CGRectMake(rightEdge - fit.width, statsY, fit.width, statsHeight);
        rightEdge -= fit.width + 9.0;
    }

    CGFloat headerBottom = 52.0;
    if (!_separatorLayer) {
        _separatorLayer = [CALayer layer];
        _separatorLayer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        [self.layer addSublayer:_separatorLayer];
    }
    _separatorLayer.frame = CGRectMake(pad, headerBottom, width - pad * 2.0, 0.5);

    CGFloat musicTop = headerBottom + 10.0;
    CGFloat bottomPad = 12.0;
    CGFloat controlsHeight = 40.0;
    CGFloat progressHeight = 42.0;

    BOOL showControls = (_hasMusic && self.expanded && (height - musicTop - bottomPad) >= 86.0);
    _progressBar.hidden = !showControls;
    _elapsedLabel.hidden = !showControls;
    _durationLabel.hidden = !showControls;
    _previousButton.hidden = !showControls;
    _playButton.hidden = !showControls;
    _nextButton.hidden = !showControls;

    _emptyLabel.hidden = _hasMusic;

    [self bringSubviewToFront:_closeButton];
    [self bringSubviewToFront:_handleButton];

    if (!showControls) {
        CGFloat available = height - musicTop - bottomPad;
        CGFloat compactArt = MIN(60.0, MAX(34.0, available));
        compactArt = MIN(compactArt, width - pad * 2.0);
        _artView.frame = CGRectMake(pad, musicTop + 1.0, compactArt, compactArt);
        _artView.layer.cornerRadius = MIN(12.0, compactArt / 4.0);
        CGFloat compactTextX = pad + compactArt + 12.0;
        CGFloat compactTextWidth = MAX(0.0, width - compactTextX - pad);
        _titleLabel.frame = CGRectMake(compactTextX, musicTop + 1.0, compactTextWidth, 20.0);
        _subtitleLabel.frame = CGRectMake(compactTextX, musicTop + 23.0, compactTextWidth, 16.0);
        _lyricsLabel.frame = CGRectZero;
        _lyricsLabel.hidden = YES;
        _emptyLabel.frame = CGRectMake(pad, musicTop, width - pad * 2.0, MAX(0.0, available));
        return;
    }

    _lyricsLabel.hidden = NO;

    CGFloat controlsTop = height - bottomPad - controlsHeight;
    CGFloat progressTop = controlsTop - progressHeight;

    CGFloat artSize = 56.0;
    CGFloat artAvailable = progressTop - musicTop - 8.0;
    if (artAvailable < artSize) artSize = MAX(34.0, artAvailable);
    artSize = MIN(artSize, width - pad * 2.0);
    _artView.frame = CGRectMake(pad, musicTop + 1.0, artSize, artSize);
    _artView.layer.cornerRadius = MIN(12.0, artSize / 4.0);

    CGFloat textX = pad + artSize + 12.0;
    CGFloat textWidth = MAX(0.0, width - textX - pad);
    _titleLabel.frame = CGRectMake(textX, musicTop, textWidth, 20.0);
    _subtitleLabel.frame = CGRectMake(textX, musicTop + 22.0, textWidth, 16.0);
    _lyricsLabel.frame = CGRectMake(textX, musicTop + 42.0, textWidth, MAX(0.0, progressTop - musicTop - 46.0));

    _progressBar.frame = CGRectMake(pad + 2.0, progressTop + 2.0, MAX(0.0, width - pad * 2.0 - 4.0), 26.0);
    _elapsedLabel.frame = CGRectMake(pad, progressTop + 29.0, 90.0, 12.0);
    _durationLabel.frame = CGRectMake(width - pad - 90.0, progressTop + 29.0, 90.0, 12.0);

    CGFloat buttonSize = 34.0;
    CGFloat spacing = 18.0;
    CGFloat totalWidth = buttonSize * 3.0 + spacing * 2.0;
    CGFloat startX = (width - totalWidth) / 2.0;
    CGFloat buttonY = controlsTop + 3.0;
    _previousButton.frame = CGRectMake(startX, buttonY, buttonSize, buttonSize);
    _playButton.frame = CGRectMake(startX + buttonSize + spacing, buttonY, buttonSize, buttonSize);
    _nextButton.frame = CGRectMake(startX + (buttonSize + spacing) * 2.0, buttonY, buttonSize, buttonSize);

    _emptyLabel.frame = CGRectZero;
}

@end

#pragma mark - 覆盖窗口与容器

/// 只让卡片区域接收触摸，其余全部穿透给下面的游戏。
@interface PGCardContainer : UIView
@property (nonatomic, weak) PGCardView *card;
@end

@implementation PGCardContainer

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.userInteractionEnabled) return nil;
    PGCardView *card = self.card;
    if (!card || card.hidden || !card.userInteractionEnabled) return nil;
    CGPoint local = [self convertPoint:point toView:card];
    if (![card pointInside:local withEvent:event]) return nil;
    return [card hitTest:local withEvent:event] ?: card;
}

@end

@interface PGOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *touchContainer;
@end

@implementation PGOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *container = self.touchContainer;
    for (UIView *view = hit; view; view = view.superview) {
        if (view == container) return hit;
    }
    return nil;
}

@end

/// 带 rootViewController 的窗口才会跟着设备旋转，横屏游戏里卡片才是正向的。
@interface PGOverlayRootViewController : UIViewController
@end

@implementation PGOverlayRootViewController

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

@end

#pragma mark - 卡片管理

@interface PGCardManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, strong) PGCardView *card;
@property (nonatomic, strong) PGCardContainer *container;
@property (nonatomic, strong) PGOverlayWindow *overlayWindow;
@property (nonatomic, weak) UIView *overlayRootView;
@property (nonatomic, weak) UIView *anchorTongue;
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
    if (PGMRInfoChangedNote) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaInfoChanged)
                                                 name:PGMRInfoChangedNote
                                               object:nil];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deviceOrientationDidChange)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deviceOrientationDidChange)
                                                 name:UIApplicationDidChangeStatusBarFrameNotification
                                               object:nil];
}

- (void)startMonitorTimer {
    __weak PGCardManager *weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
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

- (void)deviceOrientationDidChange {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self layoutCardAnimated:NO];
    });
}

- (void)monitor {
    if (!self.card) {
        // _willPresent 时 tongue 可能还没进窗口（取不到 scene），等下一拍再补。
        if (self.anchorTongue && !self.manuallyCollapsed && PGGetBool(@"enabled", YES)) {
            [self showCardForTongue:self.anchorTongue];
        }
        return;
    }
    if (self.overlayWindow.hidden) self.overlayWindow.hidden = NO;
    if (!self.card.superview) {
        [self attachCardToContainer];
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

#pragma mark 窗口

- (UIWindow *)overlayWindowForScene:(UIWindowScene *)scene {
    if (self.overlayWindow) return self.overlayWindow;

    PGOverlayWindow *window = nil;
    if (scene) {
        window = [[PGOverlayWindow alloc] initWithWindowScene:scene];
    }
    if (!window) {
        CGRect frame = [UIScreen mainScreen].bounds;
        window = [[PGOverlayWindow alloc] initWithFrame:frame];
    }
    window.windowLevel = UIWindowLevelStatusBar + 1.0;
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;

    PGOverlayRootViewController *root = [[PGOverlayRootViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    window.rootViewController = root;

    self.overlayRootView = root.view;
    self.overlayWindow = window;
    return window;
}

- (void)attachCardToContainer {
    if (!self.card || !self.container || !self.overlayRootView) return;
    if (self.container.superview != self.overlayRootView) {
        [self.container removeFromSuperview];
        [self.overlayRootView addSubview:self.container];
    }
    self.container.frame = self.overlayRootView.bounds;
    self.container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.container layoutIfNeeded];
    if (self.card.superview != self.container) {
        [self.card removeFromSuperview];
        [self.container addSubview:self.card];
    }
    self.container.hidden = NO;
    self.card.hidden = NO;
    self.overlayWindow.touchContainer = self.container;
    [self.container bringSubviewToFront:self.card];
}

- (void)applyPreferences {
    if (!self.card) return;
    [self.card applyPreferences];
    [self layoutCardAnimated:NO];
}

#pragma mark 布局

- (void)tongueWillPresent:(UIView *)tongue {
    if (!PGGetBool(@"enabled", YES)) return;
    self.anchorTongue = tongue;
    self.manuallyCollapsed = NO;
    self.hiddenForNotificationCenter = NO;
    [self showCardForTongue:tongue];
}

- (void)tongueDidPresent:(UIView *)tongue {
    self.anchorTongue = tongue;
    if (!self.card || !self.overlayWindow) {
        [self showCardForTongue:tongue];
    } else {
        [self layoutCardAnimated:NO];
    }
}

- (void)showCardForTongue:(UIView *)tongue {
    if (!PGGetBool(@"enabled", YES)) return;

    UIWindow *hostWindow = tongue.window;
    // 还没挂到窗口上：先记下锚点，等 _didPresent 或监视定时器再真正创建。
    if (!hostWindow) {
        self.anchorTongue = tongue;
        return;
    }

    UIWindowScene *scene = hostWindow.windowScene;
    PGOverlayWindow *overlay = [self overlayWindowForScene:scene];
    if (!overlay) return;

    BOOL shouldAnimate = (self.card == nil);
    if (!self.card) {
        self.card = [[PGCardView alloc] initWithFrame:CGRectZero];
        __weak PGCardManager *weakManager = self;
        self.card.onCollapse = ^{
            [weakManager hideCardAnimated:YES manual:YES];
        };
        self.card.onExpandedChange = ^{
            [weakManager layoutCardAnimated:YES];
        };
    }
    if (!self.container) {
        self.container = [[PGCardContainer alloc] initWithFrame:overlay.bounds];
        self.container.backgroundColor = [UIColor clearColor];
        self.container.userInteractionEnabled = YES;
        self.container.clipsToBounds = NO;
        [self.container addSubview:self.card];
    }
    self.container.card = self.card;

    self.overlayWindow.hidden = NO;
    self.overlayWindow.touchContainer = self.container;

    [self attachCardToContainer];

    [self.card applyPreferences];
    [self layoutCardAnimated:NO];

    // 首次 present 时窗口的 safeAreaInsets 还没算好，等下一帧再对位一次。
    __weak PGCardManager *weakManager = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakManager layoutCardAnimated:NO];
    });

    [self.container bringSubviewToFront:self.card];
    self.card.hidden = NO;

    if (shouldAnimate) {
        [self.card flashIn];
    } else if (self.card.hidden) {
        self.card.hidden = NO;
    }

    if (PGGetBool(@"presentHaptic", YES)) {
        PGHapticLight();
    }
}

/// 按锚点离哪条边最近决定卡片摆在锚点的哪一侧：横屏时抓取条在左边缘，
/// 旧逻辑固定“画在下方”会把卡片挤到屏幕左上角。
- (CGRect)cardFrameForAnchor:(CGRect)anchor hostBounds:(CGRect)host width:(CGFloat)width height:(CGFloat)height {
    UIEdgeInsets safe = self.container.safeAreaInsets;
    CGFloat margin = 8.0;
    CGFloat minX = safe.left + margin;
    CGFloat maxX = CGRectGetWidth(host) - safe.right - margin;
    CGFloat minY = safe.top + margin;
    CGFloat maxY = CGRectGetHeight(host) - safe.bottom - margin;
    if (maxX - minX < 60.0) { minX = margin; maxX = CGRectGetWidth(host) - margin; }
    if (maxY - minY < 60.0) { minY = margin; maxY = CGRectGetHeight(host) - margin; }

    CGFloat finalWidth = MIN(width, maxX - minX);
    CGFloat finalHeight = MIN(height, maxY - minY);

    CGRect frame = CGRectZero;
    if (CGRectIsEmpty(anchor) || CGRectGetWidth(anchor) <= 0 || CGRectGetHeight(anchor) <= 0) {
        frame = CGRectMake(CGRectGetMidX(host) - finalWidth / 2.0, minY + 4.0, finalWidth, finalHeight);
    } else {
        CGFloat distanceTop = CGRectGetMinY(anchor) - minY;
        CGFloat distanceLeft = CGRectGetMinX(anchor) - minX;
        CGFloat distanceRight = maxX - CGRectGetMaxX(anchor);
        CGFloat distanceBottom = maxY - CGRectGetMaxY(anchor);
        CGFloat smallest = MIN(MIN(distanceTop, distanceLeft), MIN(distanceRight, distanceBottom));

        if (smallest == distanceTop) {
            frame.origin.x = CGRectGetMidX(anchor) - finalWidth / 2.0;
            frame.origin.y = CGRectGetMaxY(anchor) + 8.0;
        } else if (smallest == distanceBottom) {
            frame.origin.x = CGRectGetMidX(anchor) - finalWidth / 2.0;
            frame.origin.y = CGRectGetMinY(anchor) - finalHeight - 8.0;
        } else if (smallest == distanceLeft) {
            frame.origin.x = CGRectGetMaxX(anchor) + 8.0;
            frame.origin.y = CGRectGetMidY(anchor) - finalHeight / 2.0;
        } else {
            frame.origin.x = CGRectGetMinX(anchor) - finalWidth - 8.0;
            frame.origin.y = CGRectGetMidY(anchor) - finalHeight / 2.0;
        }
    }

    frame.origin.x = MIN(MAX(frame.origin.x, minX), MAX(minX, maxX - finalWidth));
    frame.origin.y = MIN(MAX(frame.origin.y, minY), MAX(minY, maxY - finalHeight));
    frame.size = CGSizeMake(finalWidth, finalHeight);
    return frame;
}

- (void)layoutCardAnimated:(BOOL)animated {
    if (!self.card || !self.container) return;

    CGRect host = self.container.bounds;
    if (CGRectIsEmpty(host)) host = self.overlayWindow.bounds;
    if (CGRectIsEmpty(host)) return;

    CGRect anchor = CGRectZero;
    if (self.anchorTongue && self.anchorTongue.window && self.container.window) {
        anchor = [self.anchorTongue convertRect:self.anchorTongue.bounds toView:self.container];
    }

    CGFloat scale = MIN(1.3, MAX(0.8, PGGetFloat(@"cardScale", 1.0)));
    CGFloat baseWidth = MIN(430.0, MAX(240.0, PGGetFloat(@"cardWidth", 356.0)));
    CGFloat baseHeight = MIN(440.0, MAX(150.0, PGGetFloat(@"cardHeight", 246.0)));

    BOOL expanded = (self.card.expanded && PGGetBool(@"longPressControls", YES));
    CGFloat minimumHeight = expanded ? 220.0 : 150.0;
    CGFloat width = MIN(baseWidth * scale, CGRectGetWidth(host) - 24.0);
    CGFloat height = MIN(MAX(baseHeight * scale, minimumHeight), CGRectGetHeight(host) - 24.0);
    width = MAX(200.0, width);
    height = MAX(120.0, height);

    CGRect frame = [self cardFrameForAnchor:anchor hostBounds:host width:width height:height];

    void (^apply)(void) = ^{
        self.card.frame = frame;
        [self.card setNeedsLayout];
        [self.card layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:apply completion:nil];
    } else {
        apply();
    }
}

#pragma mark 收起 / 关闭

- (void)hideCardAnimated:(BOOL)animated manual:(BOOL)manual {
    if (manual) self.manuallyCollapsed = YES;

    PGCardView *card = self.card;
    self.card = nil;
    self.anchorTongue = nil;
    self.hiddenForNotificationCenter = NO;

    if (!card) {
        [self teardownOverlay];
        return;
    }

    [card collapseAnimated:animated completion:^{
        [self teardownOverlay];
    }];
}

- (void)teardownOverlay {
    if (self.card) return;
    [self.container removeFromSuperview];
    self.container = nil;
    if (self.overlayWindow) {
        self.overlayWindow.touchContainer = nil;
        self.overlayWindow.hidden = YES;
        self.overlayWindow.rootViewController = nil;
    }
    self.overlayWindow = nil;
    self.overlayRootView = nil;
}

@end

#pragma mark - Hooks

static void (*gOrigWillPresent)(id, SEL);
static void (*gOrigDidPresent)(id, SEL);
static void (*gOrigWillDismiss)(id, SEL);
static void (*gOrigDidDismiss)(id, SEL);

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
    // 面板收起时抓取条会回到屏幕边缘，等动画结束后重新对位。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[PGCardManager sharedManager] tongueDidPresent:(UIView *)self];
    });
}

static void PGHookDidDismiss(id self, SEL _cmd) {
    if (gOrigDidDismiss) gOrigDidDismiss(self, _cmd);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PGCardManager sharedManager] tongueDidPresent:(UIView *)self];
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

static NSUInteger PGPrefsChangeGeneration = 0;

static void PGPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    PGInvalidatePrefsCache();
    // 设置页滑杆是连续回调，这里合并 120ms 内的多次变更，避免反复重建卡片。
    NSUInteger generation = ++PGPrefsChangeGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != PGPrefsChangeGeneration) return;
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
}

__attribute__((constructor)) static void GrabberCardInitialize(void) {
    @autoreleasepool {
        PGLoadMediaRemote();

        if (PGMRRegisterFunc) {
            PGMRRegisterFunc(dispatch_get_main_queue());
        }

        // 提前创建管理器，注册 MediaRemote / 方向变化通知与监视定时器。
        (void)[PGCardManager sharedManager];

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
