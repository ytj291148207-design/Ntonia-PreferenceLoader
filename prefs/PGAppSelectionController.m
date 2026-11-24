#import "PGAppSelectionController.h"
#import <objc/message.h>

static NSString *const PGAppDomain = @"com.netskao.perfectgrabber";
static NSString *const PGAppAllowListKey = @"LandscapeAppAllowList";
static NSString *const PGAppChangedNotification = @"com.netskao.perfectgrabber.settingschanged";

/// 每个 App 存一条：name / bundleID / path / iconPath。
static NSString *const PGAppNameKey = @"name";
static NSString *const PGAppBundleKey = @"bundleID";
static NSString *const PGAppPathKey = @"path";
static NSString *const PGAppIconPathKey = @"iconPath";

#pragma mark - 偏好读写

static NSArray<NSString *> *PGReadAllowList(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)PGAppAllowListKey,
                                                        (__bridge CFStringRef)PGAppDomain);
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSArray class]] ? object : @[];
}

static void PGWriteAllowList(NSArray<NSString *> *list) {
    NSArray *sorted = [list sortedArrayUsingSelector:@selector(compare:)];
    CFPreferencesSetAppValue((__bridge CFStringRef)PGAppAllowListKey,
                             (__bridge CFPropertyListRef)sorted,
                             (__bridge CFStringRef)PGAppDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)PGAppDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)PGAppChangedNotification,
                                         NULL, NULL, YES);
}

#pragma mark - 已安装 App 枚举

/// ⚠️ 1.1-30 的关键修复：TrollStore（巨魔）装的 App 在设置列表里"找不到"。
///
/// 原因有三个，全都出在老实现上：
///   ① 只查了 LSApplicationWorkspace 的 allInstalledApplications。巨魔绕过了 installd，
///      只把 App 塞进 LS 的某几个索引里，很多机型上这个接口直接看不到它们；
///      （巨魔自己的安装记录在 MobileInstallation 里也没有，所以老代码那条 plist 兜底同样兜不住。）
///   ② 老代码 `if (!name.length) continue;` —— 巨魔 App 的 localizedName 有时返回空
///      （InfoPlist.strings 缺失 / ldid 伪签名后 LS 不解析本地化），整条被丢掉，名字都没有。
///   ③ 老代码要求 applicationType == "User"，巨魔装的会被标成 Internal，一样被筛掉。
///
/// 现在改成"多路合并、任一命中就收"：LS 三个接口 + 扫 App 目录 + MobileInstallation 记录。
static NSString *const PGSystemAppPrefix = @"com.apple.";

static BOOL PGBundleIdentifierIsIgnored(NSString *bundleIdentifier) {
    if (![bundleIdentifier isKindOfClass:[NSString class]]) return YES;
    if (bundleIdentifier.length == 0) return YES;
    if ([bundleIdentifier hasPrefix:PGSystemAppPrefix]) return YES;   // 系统 App / Web App
    return NO;
}

/// 字典里按 key 取字符串，类型不对就当没有 —— 私有对象吐出来的东西一律不信。
static NSString *PGEntryString(NSDictionary *entry, NSString *key) {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    id value = entry[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *PGDisplayNameFromInfoPlist(NSDictionary *info, NSString *fallback) {
    if ([info isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName", @"CFBundleExecutable"]) {
            id value = info[key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
        }
    }
    return [fallback isKindOfClass:[NSString class]] ? fallback : nil;
}

/// 从 Info.plist 的图标声明里收集候选文件名（新式 CFBundleIcons + 老式 CFBundleIconFiles）。
static void PGCollectIconNames(NSDictionary *icons, NSMutableArray<NSString *> *names) {
    if (![icons isKindOfClass:[NSDictionary class]]) return;

    id primary = icons[@"CFBundlePrimaryIcon"];
    if ([primary isKindOfClass:[NSDictionary class]]) {
        id files = ((NSDictionary *)primary)[@"CFBundleIconFiles"];
        if ([files isKindOfClass:[NSArray class]]) [names addObjectsFromArray:files];
        id iconName = ((NSDictionary *)primary)[@"CFBundleIconName"];
        if ([iconName isKindOfClass:[NSString class]]) [names addObject:iconName];
    }
}

/// 在 .app 包里找一张能用的大图标。巨魔装的 App 走不通私有取图接口时全靠这条路。
static NSString *PGIconPathForAppBundle(NSString *appPath, NSDictionary *info) {
    if (![appPath isKindOfClass:[NSString class]] || appPath.length == 0) return nil;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    PGCollectIconNames(info[@"CFBundleIcons"], names);
    PGCollectIconNames(info[@"CFBundleIcons~ipad"], names);
    id legacy = info[@"CFBundleIconFiles"];
    if ([legacy isKindOfClass:[NSArray class]]) [names addObjectsFromArray:legacy];
    id legacyIpad = info[@"CFBundleIconFiles~ipad"];
    if ([legacyIpad isKindOfClass:[NSArray class]]) [names addObjectsFromArray:legacyIpad];
    id iconFile = info[@"CFBundleIconFile"];
    if ([iconFile isKindOfClass:[NSString class]]) [names addObject:iconFile];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *suffixes = @[@"@3x~iphone.png", @"@3x.png", @"@2x~iphone.png",
                                      @"@2x.png", @"~iphone.png", @".png"];
    // 数组末尾通常是最大尺寸那一张，倒着找。
    for (NSString *name in [names reverseObjectEnumerator]) {
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;
        NSString *base = [name stringByDeletingPathExtension];
        for (NSString *suffix in suffixes) {
            NSString *candidate = [appPath stringByAppendingPathComponent:
                                   [base stringByAppendingString:suffix]];
            if ([fileManager fileExistsAtPath:candidate]) return candidate;
        }
        NSString *direct = [appPath stringByAppendingPathComponent:name];   // 文件名可能已带扩展名
        if ([fileManager fileExistsAtPath:direct]) return direct;
    }

    // 最后一招：扫目录里所有 icon 类 PNG，挑体积最大的（≈分辨率最高）。
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:appPath error:NULL];
    NSString *best = nil;
    unsigned long long bestSize = 0;
    for (NSString *entry in entries) {
        if (![entry.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        if ([entry rangeOfString:@"icon" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        NSString *full = [appPath stringByAppendingPathComponent:entry];
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:full error:NULL];
        unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
        if (size > bestSize) {
            bestSize = size;
            best = full;
        }
    }
    return best;
}

/// 同一条 App 可能被好几路同时看到，这里做合并：名字取第一个"像样"的，路径/图标路径缺了才补。
static void PGMergeAppEntry(NSMutableDictionary<NSString *, NSMutableDictionary *> *collector,
                            NSString *bundleIdentifier,
                            NSString *name,
                            NSString *appPath,
                            NSString *iconPath) {
    if (PGBundleIdentifierIsIgnored(bundleIdentifier)) return;

    NSMutableDictionary *entry = collector[bundleIdentifier];
    if (!entry) {
        entry = [NSMutableDictionary dictionary];
        entry[PGAppBundleKey] = bundleIdentifier;
        entry[PGAppNameKey] = @"";
        collector[bundleIdentifier] = entry;
    }

    NSString *currentName = PGEntryString(entry, PGAppNameKey);
    BOOL hasGoodName = currentName.length > 0 && ![currentName isEqualToString:bundleIdentifier];
    if (!hasGoodName && [name isKindOfClass:[NSString class]] && name.length > 0) {
        entry[PGAppNameKey] = name;
    }

    NSString *currentPath = PGEntryString(entry, PGAppPathKey);
    if (currentPath.length == 0 && [appPath isKindOfClass:[NSString class]] && appPath.length > 0) {
        entry[PGAppPathKey] = appPath;
    }
    NSString *currentIcon = PGEntryString(entry, PGAppIconPathKey);
    if (currentIcon.length == 0 && [iconPath isKindOfClass:[NSString class]] && iconPath.length > 0) {
        entry[PGAppIconPathKey] = iconPath;
    }
}

/// ① LaunchServices：三个接口全试一遍。正常从 App Store / 侧载装的 App 都在这；
/// 巨魔装的有一部分机型能在这里出现（在 Internal 那一类），有一部分完全看不到。
static void PGCollectFromWorkspace(NSMutableDictionary<NSString *, NSMutableDictionary *> *collector) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return;

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
    if (!workspace) return;

    NSMutableArray *batches = [NSMutableArray array];
    @try {
        id installed = ((id (*)(id, SEL))objc_msgSend)(workspace, @selector(allInstalledApplications));
        if (installed) [batches addObject:installed];
    } @catch (NSException *exception) {
        NSLog(@"[PerfectGrabber] allInstalledApplications 抛异常: %@", exception);
    }
    @try {
        id all = ((id (*)(id, SEL))objc_msgSend)(workspace, @selector(allApplications));
        if (all) [batches addObject:all];
    } @catch (NSException *exception) {
        (void)exception;
    }

    SEL enumerateSelector = @selector(enumerateApplicationsOfType:block:);
    if ([workspace respondsToSelector:enumerateSelector]) {
        // 0 = User，2 = Internal。巨魔装的 App 在部分系统版本上被归到 Internal。
        for (NSNumber *typeBox in @[@0, @2]) {
            NSMutableArray *collected = [NSMutableArray array];
            @try {
                ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(
                    workspace, enumerateSelector, (NSUInteger)typeBox.unsignedIntegerValue,
                    ^(id proxy) {
                        if (proxy) [collected addObject:proxy];
                    });
            } @catch (NSException *exception) {
                (void)exception;
            }
            if (collected.count > 0) [batches addObject:collected];
        }
    }

    for (id batch in batches) {
        if (![batch respondsToSelector:@selector(count)]) continue;
        for (id proxy in batch) {
            NSString *bundleIdentifier = nil;
            NSString *name = nil;
            NSURL *bundleURL = nil;
            @try {
                bundleIdentifier = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleIdentifier));
                name = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName));
                bundleURL = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleURL));
            } @catch (NSException *exception) {
                continue;
            }
            if (PGBundleIdentifierIsIgnored(bundleIdentifier)) continue;
            if (![bundleURL isKindOfClass:[NSURL class]]) bundleURL = nil;
            if (![name isKindOfClass:[NSString class]]) name = nil;

            NSString *appPath = bundleURL.path;
            if (name.length == 0 && appPath.length > 0) {
                // 巨魔 App 的 localizedName 常为空，直接翻它自己的 Info.plist。
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                      [appPath stringByAppendingPathComponent:@"Info.plist"]];
                name = PGDisplayNameFromInfoPlist(info, [appPath.lastPathComponent stringByDeletingPathExtension]);
            }
            PGMergeAppEntry(collector, bundleIdentifier, name, appPath, nil);
        }
    }
}

/// 扫一个目录下的 .app。depth 控制往下钻几层（巨魔的路径是 <UUID>/<Name>.app，两层够）。
static void PGScanAppDirectory(NSString *root,
                               NSInteger depth,
                               NSMutableDictionary<NSString *, NSMutableDictionary *> *collector) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:root error:NULL];
    if (entries.count == 0) return;

    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        NSString *fullPath = [root stringByAppendingPathComponent:entry];

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory] || !isDirectory) continue;

        if ([entry hasSuffix:@".app"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [fullPath stringByAppendingPathComponent:@"Info.plist"]];
            if (![info isKindOfClass:[NSDictionary class]]) continue;

            // 扩展（.appex）也长在 .app 里，它的 Info.plist 带 NSExtension，不是能启动的 App。
            if (info[@"NSExtension"] != nil) continue;
            id packageType = info[@"CFBundlePackageType"];
            if ([packageType isKindOfClass:[NSString class]] && ![packageType isEqualToString:@"APPL"]) continue;

            NSString *bundleIdentifier = info[@"CFBundleIdentifier"];
            if (PGBundleIdentifierIsIgnored(bundleIdentifier)) continue;

            NSString *fallbackName = [entry stringByDeletingPathExtension];
            NSString *name = PGDisplayNameFromInfoPlist(info, fallbackName);
            NSString *iconPath = PGIconPathForAppBundle(fullPath, info);
            PGMergeAppEntry(collector, bundleIdentifier, name, fullPath, iconPath);
            continue;   // 不再往 .app 里钻
        }

        if (depth > 0) PGScanAppDirectory(fullPath, depth - 1, collector);
    }
}

/// ② 文件系统：巨魔装在这里（/var/containers/Bundle/Application/<UUID>/<Name>.app）。
/// 越狱商店装的 App 通常在 /Applications。rootless 环境还有 /var/jb/Applications。
static void PGCollectFromBundleDirectories(NSMutableDictionary<NSString *, NSMutableDictionary *> *collector) {
    NSArray<NSString *> *roots = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application",   // 和上面是同一目录（软链），加着防路径差异
        @"/Applications",
        @"/var/jb/Applications",
    ];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (NSString *root in roots) {
        NSString *resolved = [root stringByResolvingSymlinksInPath] ?: root;
        if ([visited containsObject:resolved]) continue;   // 软链指向同一目录，别扫两遍
        [visited addObject:resolved];

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) continue;
        PGScanAppDirectory(root, 2, collector);
    }
}

/// ③ MobileInstallation 的 LastLaunchServicesMap.plist：LS 数据库不可用时的兜底。
/// 注意巨魔 App 不在这里（它不走 installd），所以这条路只是补充，不是主力。
static void PGCollectFromInstallationMap(NSMutableDictionary<NSString *, NSMutableDictionary *> *collector) {
    NSDictionary *map = [NSDictionary dictionaryWithContentsOfFile:
                         @"/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist"];
    if (![map isKindOfClass:[NSDictionary class]]) return;

    id section = map[@"User"];
    if (![section isKindOfClass:[NSDictionary class]]) section = map;
    if (![section isKindOfClass:[NSDictionary class]]) return;

    [(NSDictionary *)section enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) return;

        NSString *bundleIdentifier = key;
        NSString *name = nil;
        NSString *path = nil;
        if ([value isKindOfClass:[NSDictionary class]]) {
            NSDictionary *info = (NSDictionary *)value;
            id identifier = info[@"Identifier"];
            if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) {
                bundleIdentifier = identifier;
            }
            name = PGDisplayNameFromInfoPlist(info, nil);
            id bundlePath = info[@"Path"];
            if ([bundlePath isKindOfClass:[NSString class]] && [bundlePath length] > 0) path = bundlePath;
        }
        if (PGBundleIdentifierIsIgnored(bundleIdentifier)) return;
        PGMergeAppEntry(collector, bundleIdentifier, name, path, nil);
    }];
}

/// 三路合并后统一排序（按显示名，取不到名字就用 bundle id 兜底）。
static NSArray<NSDictionary *> *PGInstalledApplications(void) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *collector = [NSMutableDictionary dictionary];
    PGCollectFromWorkspace(collector);
    PGCollectFromBundleDirectories(collector);
    PGCollectFromInstallationMap(collector);

    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:collector.count];
    for (NSMutableDictionary *entry in collector.allValues) {
        NSString *name = PGEntryString(entry, PGAppNameKey);
        if (name.length == 0) entry[PGAppNameKey] = entry[PGAppBundleKey];   // 名字实在没有就用 bundle id
        [result addObject:entry];
    }

    [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSString *leftName = PGEntryString(left, PGAppNameKey) ?: @"";
        NSString *rightName = PGEntryString(right, PGAppNameKey) ?: @"";
        return [leftName localizedStandardCompare:rightName];
    }];
    return result;
}

/// 少数条目（LS 里只有注册记录、bundleURL 为空）拿不到路径，用 proxy 再问一次。
/// 只在真的缺路径时才调，拿到就写回 entry，不会每行都查。
static NSString *PGAppPathForBundleIdentifier(NSString *bundleIdentifier) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass || ![proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) return nil;

    NSString *path = nil;
    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass,
                                                       @selector(applicationProxyForIdentifier:),
                                                       bundleIdentifier);
        if (proxy) {
            NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleURL));
            if ([url isKindOfClass:[NSURL class]]) path = url.path;
        }
    } @catch (NSException *exception) {
        (void)exception;
        path = nil;
    }
    return path;
}

/// 直接把 .app 当 bundle，从它的 Assets.car 里取 AppIcon。
/// 设置进程里 UIApplication 的私有取图接口经常直接返回 nil（截图里那种"只有名字没图标"），
/// 但 App 自己的 bundle 是本地文件，imageNamed:inBundle: 一定能读到，普通 App 和巨魔 App 通吃。
static UIImage *PGIconFromAppBundle(NSString *appPath, NSDictionary *info) {
    if (![appPath isKindOfClass:[NSString class]] || appPath.length == 0) return nil;

    NSBundle *bundle = [NSBundle bundleWithPath:appPath];
    if (!bundle) return nil;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    // Info.plist 里的 CFBundleIconName 就是 asset 里的名字（新式 App 基本都是 "AppIcon"）。
    if ([info isKindOfClass:[NSDictionary class]]) {
        id icons = info[@"CFBundleIcons"];
        if ([icons isKindOfClass:[NSDictionary class]]) {
            id primary = ((NSDictionary *)icons)[@"CFBundlePrimaryIcon"];
            if ([primary isKindOfClass:[NSDictionary class]]) {
                id iconName = ((NSDictionary *)primary)[@"CFBundleIconName"];
                if ([iconName isKindOfClass:[NSString class]] && [iconName length] > 0) {
                    [candidates addObject:iconName];
                }
            }
        }
    }
    [candidates addObjectsFromArray:@[@"AppIcon60x60", @"AppIcon", @"AppIcon-60", @"Icon-60", @"Icon"]];

    for (NSString *name in candidates) {
        UIImage *image = nil;
        @try {
            image = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
        } @catch (NSException *exception) {
            (void)exception;
            image = nil;
        }
        if ([image isKindOfClass:[UIImage class]]) return image;
    }
    return nil;
}

/// 统一重绘成 40pt 的正方形（保持比例居中）。
/// 必须重绘：直接 imageWithContentsOfFile: 读 1024×1024 的 AppIcon，
/// size 会是 1024pt，塞进 52pt 的行里直接溢出屏；而且一张解码就是 4MB。
static UIImage *PGIconThumbnail(UIImage *icon) {
    if (![icon isKindOfClass:[UIImage class]]) return nil;

    CGFloat scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 3.0;
    CGFloat side = 40.0;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)
                                                                             format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGSize imageSize = icon.size;
        if (imageSize.width <= 0.0 || imageSize.height <= 0.0) {
            [icon drawInRect:CGRectMake(0.0, 0.0, side, side)];
            return;
        }
        CGFloat ratio = MIN(side / imageSize.width, side / imageSize.height);
        CGSize drawSize = CGSizeMake(imageSize.width * ratio, imageSize.height * ratio);
        [icon drawInRect:CGRectMake((side - drawSize.width) / 2.0,
                                    (side - drawSize.height) / 2.0,
                                    drawSize.width, drawSize.height)];
    }];
}

#pragma mark - 选择页

/// 列表按"已启用 / 其他"分成两段，已启用的排在最上面 —— 一眼就知道自己开了哪几个 App。
static NSString *const PGAppSectionTitleKey = @"title";
static NSString *const PGAppSectionAppsKey = @"apps";

@interface PGAppSelectionController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
/// 每项：{ title, apps }。已启用段只在本段出现，不重复出现在下面的列表里。
@property (nonatomic, strong) NSArray<NSDictionary *> *sections;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIdentifiers;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *iconCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *iconMisses;
- (UIImage *)iconForApp:(NSDictionary *)app;
@end

@implementation PGAppSelectionController

- (instancetype)init {
    self = [super init];
    if (self) {
        _selectedIdentifiers = [NSMutableSet setWithArray:PGReadAllowList()];
        _searchText = @"";
        _sections = @[];
        _iconCache = [NSMutableDictionary dictionary];
        _iconMisses = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"选择 App";
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    } else {
        self.view.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    }

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.bounds.size.width, 44.0)];
    _searchBar.delegate = self;
    _searchBar.placeholder = @"搜索 App";
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 52.0;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.tableHeaderView = _searchBar;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_tableView];

    // 枚举 App 要读 LS 数据库 + 扫一遍 App 目录，别卡住第一帧。
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *apps = PGInstalledApplications();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.allApps = apps;
            [strongSelf applyFilter];
        });
    });
}

/// 图标按行懒加载。之前是整个列表加载完就一次性批量取图 —— 上百次私有调用堆在主线程上，
/// 设置 App 直接卡住。现在只给屏幕里那几行取，取过就进缓存。
- (UIImage *)iconForApp:(NSDictionary *)app {
    NSString *bundleIdentifier = PGEntryString(app, PGAppBundleKey);
    if (bundleIdentifier.length == 0) return nil;

    UIImage *cached = self.iconCache[bundleIdentifier];
    if (cached) return cached;
    if ([self.iconMisses containsObject:bundleIdentifier]) return nil;

    UIImage *icon = nil;

    // ① 系统私有接口：能出图就最快（无 IO）。
    SEL iconSelector = @selector(_applicationIconImageForBundleIdentifier:format:scale:);
    if ([UIApplication.sharedApplication respondsToSelector:iconSelector]) {
        CGFloat scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 3.0;
        @try {
            icon = ((id (*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(
                UIApplication.sharedApplication, iconSelector, bundleIdentifier, (NSInteger)0, scale);
        } @catch (NSException *exception) {
            (void)exception;
            icon = nil;
        }
    }
    if (![icon isKindOfClass:[UIImage class]]) icon = nil;

    // ② 取不到（设置进程里这个私有接口常年返回 nil）：直接进 .app 的 bundle，
    //    从 Assets.car 里按 AppIcon 取。这条路对普通 App 和巨魔 App 都成立。
    NSString *appPath = PGEntryString(app, PGAppPathKey);
    if (appPath.length == 0) {
        appPath = PGAppPathForBundleIdentifier(bundleIdentifier);
        if (appPath.length > 0 && [app isKindOfClass:[NSMutableDictionary class]]) {
            ((NSMutableDictionary *)app)[PGAppPathKey] = appPath;
        }
    }
    if (!icon && appPath.length > 0) {
        icon = PGIconFromAppBundle(appPath, nil);
    }

    // ③ 包里没有 Assets.car（老 App 用散装 PNG）：用枚举时算好的图标文件路径直接读。
    if (!icon) {
        NSString *iconPath = PGEntryString(app, PGAppIconPathKey);
        if (iconPath.length == 0 && appPath.length > 0) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [appPath stringByAppendingPathComponent:@"Info.plist"]];
            iconPath = PGIconPathForAppBundle(appPath, info);
            if (iconPath.length > 0 && [app isKindOfClass:[NSMutableDictionary class]]) {
                ((NSMutableDictionary *)app)[PGAppIconPathKey] = iconPath;
            }
        }
        if (iconPath.length > 0) {
            icon = [UIImage imageWithContentsOfFile:iconPath];
            if (![icon isKindOfClass:[UIImage class]]) icon = nil;
        }
    }

    if (icon) {
        UIImage *thumbnail = PGIconThumbnail(icon) ?: icon;
        self.iconCache[bundleIdentifier] = thumbnail;
        return thumbnail;
    }
    [self.iconMisses addObject:bundleIdentifier];
    return nil;
}

/// 过滤 + 分段。已启用的排第一段，其余排第二段；两段内部都按名字本地化排序。
- (void)applyFilter {
    NSString *keyword = [self.searchText stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    NSArray<NSDictionary *> *source = self.allApps ?: @[];
    NSMutableArray<NSDictionary *> *enabled = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *others = [NSMutableArray array];

    for (NSDictionary *app in source) {
        NSString *name = PGEntryString(app, PGAppNameKey) ?: @"";
        NSString *bundleID = PGEntryString(app, PGAppBundleKey);
        if (![bundleID isKindOfClass:[NSString class]]) continue;

        if (keyword.length > 0) {
            BOOL matched = ([name rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                           ([bundleID rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound);
            if (!matched) continue;
        }
        if ([self.selectedIdentifiers containsObject:bundleID]) {
            [enabled addObject:app];
        } else {
            [others addObject:app];
        }
    }

    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    if (enabled.count > 0) {
        [sections addObject:@{
            PGAppSectionTitleKey: [NSString stringWithFormat:@"已启用（%lu）", (unsigned long)enabled.count],
            PGAppSectionAppsKey: enabled
        }];
    }
    if (others.count > 0 || sections.count == 0) {
        [sections addObject:@{
            PGAppSectionTitleKey: enabled.count > 0 ? @"其他 App" : @"全部 App",
            PGAppSectionAppsKey: others
        }];
    }
    self.sections = sections;

    // 重排后行数会变（开关一开，那一行就往上跳到"已启用"段），
    // 顺手把 contentOffset 夹回合法范围，免得列表跳到一半白屏。
    CGFloat offsetY = self.tableView.contentOffset.y;
    [self.tableView reloadData];
    CGFloat maxOffsetY = MAX(0.0, self.tableView.contentSize.height - CGRectGetHeight(self.tableView.bounds));
    if (offsetY > maxOffsetY) {
        self.tableView.contentOffset = CGPointMake(0.0, maxOffsetY);
    }
}

- (NSDictionary *)appAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sections.count) return nil;
    NSArray *apps = self.sections[indexPath.section][PGAppSectionAppsKey];
    if (![apps isKindOfClass:[NSArray class]]) return nil;
    if (indexPath.row >= (NSInteger)apps.count) return nil;
    return apps[indexPath.row];
}

#pragma mark 搜索

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.searchText = searchText ?: @"";
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self.searchBar resignFirstResponder];
}

#pragma mark 列表

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.allApps.count == 0) return 1;   // 一个 App 都没取到：单段一行解释文字
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.allApps.count == 0) return 1;
    if (section >= (NSInteger)self.sections.count) return 0;
    NSArray *apps = self.sections[section][PGAppSectionAppsKey];
    return [apps isKindOfClass:[NSArray class]] ? (NSInteger)apps.count : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.allApps.count == 0) return nil;
    if (section >= (NSInteger)self.sections.count) return nil;
    NSString *title = self.sections[section][PGAppSectionTitleKey];
    return [title isKindOfClass:[NSString class]] ? title : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"PGAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
    }

    if (self.allApps.count == 0) {
        cell.textLabel.text = @"没读到已安装的 App";
        cell.detailTextLabel.text = @"退出设置再进一次试试";
        cell.imageView.image = nil;
        cell.accessoryView.hidden = YES;
        return cell;
    }

    NSDictionary *app = [self appAtIndexPath:indexPath];
    if (!app) return cell;

    cell.accessoryView.hidden = NO;
    cell.textLabel.text = PGEntryString(app, PGAppNameKey) ?: @"";
    cell.detailTextLabel.text = PGEntryString(app, PGAppBundleKey) ?: @"";
    UIImage *icon = [self iconForApp:app];
    if (icon) {
        cell.imageView.image = icon;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.layer.cornerRadius = 9.0;
        cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;
        cell.imageView.clipsToBounds = YES;
    } else {
        cell.imageView.image = nil;
    }

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    toggle.on = [self.selectedIdentifiers containsObject:app[PGAppBundleKey]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (self.allApps.count == 0) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    [toggle setOn:!toggle.isOn animated:YES];
    [self commitToggle:toggle atIndexPath:indexPath];   // 整行都能点，不用非得戳那个小开关
}

- (void)toggleChanged:(UISwitch *)toggle {
    // 搜索过滤后 indexPath 会变，用触摸点反查行号，别依赖 tag。
    CGPoint point = [toggle convertPoint:CGPointZero toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;
    [self commitToggle:toggle atIndexPath:indexPath];
}

- (void)commitToggle:(UISwitch *)toggle atIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *app = [self appAtIndexPath:indexPath];
    NSString *bundleIdentifier = PGEntryString(app, PGAppBundleKey);
    if (![bundleIdentifier isKindOfClass:[NSString class]]) return;

    if (toggle.isOn) {
        [self.selectedIdentifiers addObject:bundleIdentifier];
    } else {
        [self.selectedIdentifiers removeObject:bundleIdentifier];
    }
    PGWriteAllowList(self.selectedIdentifiers.allObjects);

    // 这一行刚切换完就要在"已启用 / 其他"两段之间搬家。立刻 reloadData 会把开关动画打断，
    // 所以等 0.28 秒（开关滑完）再重排，视觉上才是"勾完自动飘到上面去"。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf applyFilter];
    });
}

@end
