#import "PGNowPlaying.h"
#import "PerfectGrabberPreferences.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

/// 日志统一由插件入口提供。
extern void PGDebugLog(NSString *format, ...);

#pragma mark - MediaRemote 符号

static void (*PGMRRegister)(dispatch_queue_t);
static void (*PGMRGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
static void (*PGMRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
static void (*PGMRGetClient)(dispatch_queue_t, void (^)(id));
static void (*PGMRGetPID)(dispatch_queue_t, void (^)(int));
static Boolean (*PGMRSendCommand)(int, CFDictionaryRef);
static void (*PGMRSetElapsedTime)(double);

static dispatch_once_t PGMRLoadOnce;
static BOOL PGMRRegistered = NO;

static void PGLoadMediaRemote(void) {
    dispatch_once(&PGMRLoadOnce, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                              RTLD_LAZY);
        if (!handle) {
            PGDebugLog(@"MediaRemote: dlopen 失败 (%s)", dlerror() ?: "-");
            return;
        }
        PGMRRegister = (void (*)(dispatch_queue_t))dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        PGMRGetInfo = (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        PGMRGetIsPlaying = (void (*)(dispatch_queue_t, void (^)(Boolean)))dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        PGMRGetClient = (void (*)(dispatch_queue_t, void (^)(id)))dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
        PGMRGetPID = (void (*)(dispatch_queue_t, void (^)(int)))dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        PGMRSendCommand = (Boolean (*)(int, CFDictionaryRef))dlsym(handle, "MRMediaRemoteSendCommand");
        PGMRSetElapsedTime = (void (*)(double))dlsym(handle, "MRMediaRemoteSetElapsedTime");
        PGDebugLog(@"MediaRemote: 已加载 注册=%d 信息=%d 播放态=%d 命令=%d 客户端=%d",
                   PGMRRegister != NULL, PGMRGetInfo != NULL, PGMRGetIsPlaying != NULL,
                   PGMRSendCommand != NULL, PGMRGetClient != NULL);
    });
}

#pragma mark - 前台 App / pid → bundle id

static NSString *PGStringFromObject(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// 曾经在这里用过 SpringBoardServices 的 SBFrontmostApplicationDisplayIdentifier，
/// 想拿到比 LSApplicationWorkspace 更准的前台 App。结果它在这个系统上会把一个
/// 根本不是地址的值（0x10000003）当指针返回，ARC 一 retain 就 EXC_BAD_ACCESS，
/// SpringBoard 直接进安全模式。收益只是判定更准一点，风险是整台机器进安全模式，
/// 所以这个接口永久弃用 —— 前台 App 一律走 LSApplicationWorkspace。
static NSString *PGFrontmostBundleIdentifier(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return nil;
    @try {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
        if (!workspace) return nil;
        SEL selector = @selector(frontmostApplication);
        if (![workspace respondsToSelector:selector]) return nil;
        id application = ((id (*)(id, SEL))objc_msgSend)(workspace, selector);
        return PGStringFromObject(application, @"bundleIdentifier");
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *PGBundleIdentifierForPID(int pid) {
    if (pid <= 0) return nil;
    Class controllerClass = NSClassFromString(@"SBApplicationController");
    if (!controllerClass) return nil;
    @try {
        id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, @selector(sharedInstance));
        if (!controller) return nil;
        // 不同系统版本这两个选择子有的有一个没有，挨个试，取到就算。
        for (NSString *name in @[@"applicationWithPid:", @"applicationWithProcessIdentifier:"]) {
            SEL selector = NSSelectorFromString(name);
            if (![controller respondsToSelector:selector]) continue;
            id application = ((id (*)(id, SEL, int))objc_msgSend)(controller, selector, pid);
            NSString *bundle = PGStringFromObject(application, @"bundleIdentifier");
            if (bundle.length) return bundle;
        }
        return nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

#pragma mark -

@interface PGNowPlaying ()
@property (nonatomic, assign) BOOL monitoring;
@property (nonatomic, assign, getter=isPlaying) BOOL playing;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic, copy, nullable) NSString *album;
@property (nonatomic, copy, nullable) NSString *lyrics;
@property (nonatomic, copy, nullable) NSString *bundleIdentifier;
@property (nonatomic, copy, nullable) NSString *frontmostBundleIdentifier;
@property (nonatomic, assign) double elapsed;
@property (nonatomic, assign) double duration;
@property (nonatomic, copy, nullable) NSData *artworkData;
@property (nonatomic, copy) NSString *signature;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) dispatch_queue_t queue;

/// 下面三个是"到底在不在播"的三路独立信号，任意一路为真就算在播。
/// 只信其中一路的话，某些后台（游戏里放歌）场景会一直读到 NO，歌名就永远出不来。
@property (nonatomic, assign) BOOL mrIsPlaying;          // MRMediaRemoteGetNowPlayingApplicationIsPlaying
@property (nonatomic, assign) BOOL ratePositive;         // kMRMediaRemoteNowPlayingInfoPlaybackRate > 0
@property (nonatomic, assign) BOOL elapsedAdvancing;     // 播放进度在往前走
@property (nonatomic, assign) double lastElapsed;
@property (nonatomic, assign) BOOL hasElapsedSample;
/// 诊断用：最近一次取到的原始信息，只在状态变化时打日志。
@property (nonatomic, assign) double lastRate;
/// "字典里没有标题"的键清单只打一次，别刷屏。
@property (nonatomic, assign) BOOL loggedEmptyTitleKeys;
@property (nonatomic, assign) BOOL isFetchingLyrics;
@property (nonatomic, copy) NSString *lastLyricsQuery;
@property (nonatomic, copy) NSString *lyricsQueryKey;
@property (nonatomic, strong) NSURLSessionDataTask *lyricsTask;
@property (nonatomic, strong) NSCache<NSString *, NSString *> *lyricsCache;
@property (nonatomic, strong) NSDate *lastLyricsQueryDate;
@property (nonatomic, assign) NSUInteger lyricsRequestGeneration;
@end

@implementation PGNowPlaying

+ (instancetype)sharedInstance {
    static PGNowPlaying *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _signature = @"";
        _queue = dispatch_queue_create("com.netskao.perfectgrabber.nowplaying", DISPATCH_QUEUE_SERIAL);
        _lyricsCache = [NSCache new];
        _lastLyricsQuery = @"";
    }
    return self;
}

#pragma mark 生命周期

- (void)startMonitoring {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startMonitoring];
        });
        return;
    }
    if (self.monitoring) return;

    PGLoadMediaRemote();
    if (!PGMRRegister) {
        PGDebugLog(@"MediaRemote: 注册函数缺失，音乐功能不可用");
        return;
    }

    self.monitoring = YES;
    if (!PGMRRegistered) {
        PGMRRegistered = YES;
        // 注册到主队列：通知回调直接落在主线程，读取状态和刷新 UI 都不用再跨线程。
        PGMRRegister(dispatch_get_main_queue());
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
            [center addObserver:self selector:@selector(handleMediaNotification:) name:name object:nil];
        }
    }

    // 兜底轮询：少数 App 不发声通知，1.5 秒对一次状态，代价可忽略。
    [self.pollTimer invalidate];
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.5
                                             target:self
                                           selector:@selector(handlePollTimer)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.pollTimer = timer;

    [self refresh];
}

- (void)stopMonitoring {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopMonitoring];
        });
        return;
    }
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    if (self.monitoring) {
        [NSNotificationCenter.defaultCenter removeObserver:self];
    }
    self.monitoring = NO;
}

- (void)handleMediaNotification:(NSNotification *)notification {
    // 通知里直接带着播放态，比再发一次查询快一拍，先用上。
    id value = notification.userInfo[@"kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey"];
    if ([value respondsToSelector:@selector(boolValue)]) {
        self.mrIsPlaying = [value boolValue];
        [self recomputePlaying];
    }
    [self refresh];
}

- (void)handlePollTimer {
    [self refresh];
}

#pragma mark 查询

- (void)refresh {
    if (!self.monitoring) return;
    [self fetchInfo];
    [self fetchIsPlaying];
    [self fetchClient];
    self.frontmostBundleIdentifier = PGFrontmostBundleIdentifier();
}

- (void)fetchInfo {
    if (!PGMRGetInfo) return;
    __weak typeof(self) weakSelf = self;
    PGMRGetInfo(self.queue, ^(CFDictionaryRef information) {
        NSDictionary *dictionary = information ? [(__bridge NSDictionary *)information copy] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyInformation:dictionary];
        });
    });
}

- (void)fetchIsPlaying {
    if (!PGMRGetIsPlaying) return;
    __weak typeof(self) weakSelf = self;
    PGMRGetIsPlaying(self.queue, ^(Boolean isPlaying) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.mrIsPlaying = isPlaying ? YES : NO;
            [weakSelf recomputePlaying];
        });
    });
}

- (void)fetchClient {
    __weak typeof(self) weakSelf = self;
    if (PGMRGetClient) {
        PGMRGetClient(self.queue, ^(id client) {
            NSString *bundle = PGStringFromObject(client, @"bundleIdentifier");
            int pid = 0;
            if (bundle.length == 0) {
                SEL selector = @selector(pid);
                if ([client respondsToSelector:selector]) {
                    @try {
                        pid = ((int (*)(id, SEL))objc_msgSend)(client, selector);
                    } @catch (__unused NSException *exception) {
                        pid = 0;
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf applyBundleIdentifier:bundle pid:pid];
            });
        });
        return;
    }
    if (PGMRGetPID) {
        PGMRGetPID(self.queue, ^(int pid) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf applyBundleIdentifier:nil pid:pid];
            });
        });
    }
}

- (void)resolveLyricsIfNeeded {
    if (![PerfectGrabberPreferences.sharedPreferences lyricsLookupEnabled] || !self.title.length) return;
    NSString *query = [NSString stringWithFormat:@"%@|%@|%@", self.title ?: @"", self.artist ?: @"", self.album ?: @""];
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.0f", query, self.duration];
    if ([query isEqualToString:self.lastLyricsQuery]) return;
    NSString *cached = [self.lyricsCache objectForKey:cacheKey];
    if (cached) { self.lastLyricsQuery=query; if (cached.length && !self.lyrics.length) self.lyrics = cached; return; }
    if (self.isFetchingLyrics) return;
    if (self.lastLyricsQueryDate && -[self.lastLyricsQueryDate timeIntervalSinceNow] < 2.0) return;
    self.lastLyricsQuery = query;
    self.lastLyricsQueryDate = NSDate.date;
    self.isFetchingLyrics = YES;
    NSUInteger requestGeneration = ++self.lyricsRequestGeneration;
    NSURLComponents *parts = [NSURLComponents componentsWithString:@"https://lrclib.net/api/get"];
    parts.queryItems = @[[NSURLQueryItem queryItemWithName:@"track_name" value:self.title ?: @""],
                         [NSURLQueryItem queryItemWithName:@"artist_name" value:self.artist ?: @""],
                         [NSURLQueryItem queryItemWithName:@"album_name" value:self.album ?: @""],
                         [NSURLQueryItem queryItemWithName:@"duration" value:(self.duration > 0 ? [NSString stringWithFormat:@"%.0f",self.duration] : @"")]];
    if (!parts.URL) { self.isFetchingLyrics = NO; return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:parts.URL];
    request.timeoutInterval = 5.0;
    [request setValue:@"PerfectGrabber/1.1" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    self.lyricsTask = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        PGNowPlaying *strongSelf = weakSelf; if (!strongSelf) return;
        NSString *found = nil;
        if (!error && data.length && ((NSHTTPURLResponse *)response).statusCode == 200) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) {
                id value = json[@"syncedLyrics"] ?: json[@"plainLyrics"];
                if ([value isKindOfClass:NSString.class]) found = value;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (requestGeneration != strongSelf.lyricsRequestGeneration) return;
            strongSelf.isFetchingLyrics = NO;
            [strongSelf.lyricsCache setObject:(found ?: @"") forKey:cacheKey];
            if ([strongSelf.lastLyricsQuery isEqualToString:query] && found.length) {
                strongSelf.lyrics = found;
                [strongSelf notifyIfChanged];
            }
        });
    }];
    [self.lyricsTask resume];
}

- (void)applyInformation:(NSDictionary *)dictionary {
    if (!dictionary) {
        self.title = nil;
        self.artist = nil;
        self.album = nil;
        self.lyrics = nil;
        self.lyricsQueryKey = nil;
        self.lastLyricsQuery = nil;
        self.lyricsRequestGeneration++;
        [self.lyricsTask cancel]; self.lyricsTask=nil; self.isFetchingLyrics=NO;
        self.ratePositive = NO;
        self.elapsedAdvancing = NO;
        self.hasElapsedSample = NO;
        self.elapsed = 0.0;
        self.duration = 0.0;
        self.artworkData = nil;
        [self recomputePlaying];
        return;
    }

    id title = dictionary[@"kMRMediaRemoteNowPlayingInfoTitle"];
    id artist = dictionary[@"kMRMediaRemoteNowPlayingInfoArtist"];
    id album = dictionary[@"kMRMediaRemoteNowPlayingInfoAlbum"];
    NSString *resolvedTitle = [title isKindOfClass:NSString.class] ? title : nil;
    self.artist = [artist isKindOfClass:NSString.class] ? artist : nil;
    self.album = [album isKindOfClass:NSString.class] ? album : nil;
    id lyrics = dictionary[@"kMRMediaRemoteNowPlayingInfoLyrics"] ?: dictionary[@"Lyrics"];
    NSString *playerLyrics = [lyrics isKindOfClass:NSString.class] ? lyrics : nil;
    if (resolvedTitle.length == 0) {
        // 有的 App 只填专辑名；再不行就把字典里到底有哪些键打出来，下次一眼能看出差在哪。
        if ([album isKindOfClass:NSString.class] && [album length]) {
            resolvedTitle = album;
        } else if (dictionary.count > 0 && !self.loggedEmptyTitleKeys) {
            self.loggedEmptyTitleKeys = YES;
            PGDebugLog(@"NowPlaying: 信息里没有标题，键=%@", [dictionary.allKeys componentsJoinedByString:@","]);
        }
    }
    NSString *songKey = [NSString stringWithFormat:@"%@|%@|%@", resolvedTitle ?: @"", self.artist ?: @"", self.album ?: @""];
    if (![songKey isEqualToString:self.lyricsQueryKey]) {
        self.lyrics = playerLyrics;
        self.lastLyricsQuery = nil;
        self.lyricsQueryKey = songKey;
        self.lyricsRequestGeneration++;
        [self.lyricsTask cancel]; self.lyricsTask=nil; self.isFetchingLyrics=NO;
    } else if (playerLyrics.length) {
        self.lyrics = playerLyrics;
    }
    self.title = resolvedTitle;

    // 信号二：播放速率。
    id rate = dictionary[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    if ([rate respondsToSelector:@selector(doubleValue)]) {
        self.lastRate = [rate doubleValue];
        self.ratePositive = self.lastRate > 0.01;
    } else {
        self.lastRate = 0.0;
        self.ratePositive = NO;
    }

    // 信号三：播放进度在自己往前走。暂停时进度是冻住的，这一路顺带能识破
    // "速率没上报"的 App（部分音乐 App 只在开始/结束时给一次速率）。
    id elapsed = dictionary[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    if ([elapsed respondsToSelector:@selector(doubleValue)]) {
        double value = [elapsed doubleValue];
        if (self.hasElapsedSample) {
            self.elapsedAdvancing = value > self.lastElapsed + 0.05;
        } else {
            self.elapsedAdvancing = NO;
            self.hasElapsedSample = YES;
        }
        self.lastElapsed = value;
        self.elapsed = value;
    } else {
        self.elapsedAdvancing = NO;
        self.hasElapsedSample = NO;
        self.elapsed = 0.0;
    }

    // 进度条要用的总时长与封面。这两个不进签名（否则每秒都在回调），
    // 面板自己按拍从 sharedInstance 读。
    id duration = dictionary[@"kMRMediaRemoteNowPlayingInfoDuration"];
    self.duration = [duration respondsToSelector:@selector(doubleValue)] ? [duration doubleValue] : 0.0;

    id artwork = dictionary[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    self.artworkData = [artwork isKindOfClass:NSData.class] ? artwork : nil;

    if (!self.lyrics.length) [self resolveLyricsIfNeeded];
    [self recomputePlaying];
}

- (void)applyBundleIdentifier:(NSString *)bundleIdentifier pid:(int)pid {
    NSString *resolved = bundleIdentifier.length ? bundleIdentifier : PGBundleIdentifierForPID(pid);
    self.bundleIdentifier = resolved;
    [self notifyIfChanged];
}

/// 三路信号取或。只信 MRMediaRemoteGetNowPlayingApplicationIsPlaying 会漏：
/// 在某些 App（尤其是后台播放）上它稳定返回 NO，歌名就永远出不来。
- (void)recomputePlaying {
    _playing = self.mrIsPlaying || self.ratePositive || self.elapsedAdvancing;
    [self notifyIfChanged];
}

- (void)notifyIfChanged {
    NSString *signature = [NSString stringWithFormat:@"%d|%@|%@|%@|%@|%@|%@",
                           self.playing, self.title ?: @"", self.artist ?: @"", self.album ?: @"", self.lyrics ?: @"",
                           self.bundleIdentifier ?: @"", self.frontmostBundleIdentifier ?: @""];
    if ([signature isEqualToString:self.signature]) return;
    BOOL firstTime = self.signature.length == 0;
    self.signature = signature;

    // 变化才打一行，别刷屏；这行是排查"为什么没认出在放歌"的唯一依据。
    PGDebugLog(@"NowPlaying: %@ playing=%d 标题=%@ 歌手=%@ 速率=%.2f MR播放态=%d 进度走=%d app=%@ front=%@",
               firstTime ? @"首个状态" : @"状态变化",
               self.playing, self.title ?: @"-", self.artist ?: @"-",
               self.lastRate, self.mrIsPlaying, self.elapsedAdvancing,
               self.bundleIdentifier ?: @"-", self.frontmostBundleIdentifier ?: @"-");

    if (self.onChange) self.onChange(self);
}

#pragma mark 控制

- (BOOL)canSeek {
    PGLoadMediaRemote();
    return PGMRSetElapsedTime != NULL && isfinite(self.duration) && self.duration > 0.0;
}

- (void)seekToElapsedTime:(double)seconds {
    PGLoadMediaRemote();
    // Seeking without a valid timeline or the private API would silently target an
    // arbitrary position. Keep the UI disabled and fail closed in the model too.
    if (!PGMRSetElapsedTime || !isfinite(seconds) || !isfinite(self.duration) || self.duration <= 0.0) return;
    double target = MAX(0.0, MIN(seconds, self.duration));
    PGMRSetElapsedTime(target);
    [self refresh];
}

- (void)sendCommand:(PGMediaCommand)command {
    PGLoadMediaRemote();
    if (!PGMRSendCommand) {
        PGDebugLog(@"MediaRemote: 无法发送命令 %ld（符号缺失）", (long)command);
        return;
    }
    @try {
        Boolean result = PGMRSendCommand((int)command, NULL);
        PGDebugLog(@"MediaRemote: 命令 %ld 发送 %@", (long)command, result ? @"成功" : @"失败");
    } @catch (__unused NSException *exception) {
        PGDebugLog(@"MediaRemote: 命令 %ld 抛出异常", (long)command);
    }
    // MediaRemote 的状态推送有延迟，300ms 后再对一次，让按钮立刻跟上。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

@end
