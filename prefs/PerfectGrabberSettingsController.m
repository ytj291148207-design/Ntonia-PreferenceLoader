#import "PerfectGrabberSettingsController.h"
#import "PGAppSelectionController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <math.h>
#import <spawn.h>

extern char **environ;

static NSString *const PGDomain = @"com.netskao.perfectgrabber";
static CFStringRef const PGChanged = CFSTR("com.netskao.perfectgrabber.settingschanged");
static NSString *const PGChoiceKey = @"PGChoiceKey";
static NSString *const PGChoiceTitleKey = @"PGChoiceTitle";

static id PGReadValue(NSString *key, id fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)PGDomain);
    return CFBridgingRelease(value) ?: fallback;
}

static void PGWriteValue(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)PGDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)PGDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), PGChanged,
                                         NULL, NULL, YES);
}

@interface PerfectGrabberSettingsController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *activeColorKey;
@property (nonatomic, assign) NSUInteger lastLandscapeAppCount;
- (NSString *)landscapeAppsButtonTitle;
- (NSUInteger)selectedLandscapeAppCount;
- (void)chooseLandscapeApps;
@end

@implementation PerfectGrabberSettingsController

- (BOOL)isChoiceController {
    return [[self.specifier propertyForKey:PGChoiceKey] length] > 0;
}

- (NSMutableArray *)choiceSpecifiers {
    NSString *key = [self.specifier propertyForKey:PGChoiceKey];
    NSString *title = [self.specifier propertyForKey:PGChoiceTitleKey];
    NSArray *values = @[@0, @1, @2];
    NSArray *titles = [key isEqualToString:@"GrabberStyle"]
        ? @[@"居中", @"靠左", @"靠右"]
        : @[@"常规", @"粗体", @"斜体"];
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:[PSSpecifier groupSpecifierWithName:title ?: @""]];
    for (NSUInteger index = 0; index < values.count; index++) {
        PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:titles[index]
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:Nil
                                                                 cell:PSListItemCell
                                                                 edit:Nil];
        [item setProperty:values[index] forKey:PSValueKey];
        [item setProperty:key forKey:PSKeyNameKey];
        [items addObject:item];
    }
    return items;
}

- (void)tableView:(UITableView *)tableView
 willDisplayCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self isChoiceController]) {
        return;
    }
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSNumber *value = [specifier propertyForKey:PSValueKey];
    NSString *key = [self.specifier propertyForKey:PGChoiceKey];
    NSNumber *selected = PGReadValue(key, @0);
    if ([cell respondsToSelector:@selector(setChecked:)]) {
        [(PSTableCell *)cell setChecked:[value integerValue] == [selected integerValue]];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self isChoiceController]) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSNumber *value = [specifier propertyForKey:PSValueKey];
    NSString *key = [self.specifier propertyForKey:PGChoiceKey];
    if ([value isKindOfClass:NSNumber.class]) {
        PGWriteValue(key, value);
        [tableView reloadData];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (PSSpecifier *)preferenceNamed:(NSString *)name key:(NSString *)key defaultValue:(id)defaultValue cell:(PSCellType)cell {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:@selector(setPreferenceValue:specifier:)
                                                               get:@selector(readPreferenceValue:)
                                                            detail:Nil
                                                              cell:cell
                                                              edit:Nil];
    [specifier setProperty:key forKey:PSKeyNameKey];
    [specifier setProperty:PGDomain forKey:PSDefaultsKey];
    [specifier setProperty:defaultValue forKey:PSDefaultValueKey];
    [specifier setProperty:(__bridge NSString *)PGChanged forKey:PSValueChangedNotificationKey];
    return specifier;
}

- (PSSpecifier *)choiceLinkNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:PerfectGrabberSettingsController.class
                                                              cell:PSLinkCell
                                                              edit:Nil];
    [specifier setProperty:key forKey:PGChoiceKey];
    [specifier setProperty:name forKey:PGChoiceTitleKey];
    return specifier;
}

- (PSSpecifier *)buttonNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL
                                                            detail:Nil cell:PSButtonCell edit:Nil];
    specifier.buttonAction = action;
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    if ([self isChoiceController]) {
        _specifiers = [self choiceSpecifiers];
        return _specifiers;
    }
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *main = [PSSpecifier groupSpecifierWithName:@"PerfectGrabber"];
    [main setProperty:@"RootHide source rebuild. Settings are stored through CFPreferences." forKey:PSFooterTextGroupKey];
    [items addObject:main];
    [items addObject:[self preferenceNamed:@"启用插件" key:@"EnabledPerfectGrabber" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"震动反馈" key:@"VibrationFeedback" defaultValue:@YES cell:PSSwitchCell]];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"触发方式"]];
    [items addObject:[self preferenceNamed:@"上滑时显示" key:@"ShowOnSwipeUp" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"横屏时显示（竖屏自动隐藏）" key:@"LandscapeAlwaysOn" defaultValue:@YES cell:PSSwitchCell]];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"显示"]];
    [items addObject:[self preferenceNamed:@"使用 12 小时制" key:@"Disable24H" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"充电图标" key:@"ChargingIcon" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"双行显示" key:@"TwoLine" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self choiceLinkNamed:@"布局样式" key:@"GrabberStyle"]];

    PSSpecifier *fontSize = [self preferenceNamed:@"字体大小" key:@"FontSize" defaultValue:@12.0 cell:PSSliderCell];
    [fontSize setProperty:@8.0 forKey:PSControlMinimumKey];
    [fontSize setProperty:@28.0 forKey:PSControlMaximumKey];
    [fontSize setProperty:@YES forKey:@"showValue"];
    [items addObject:fontSize];
    [items addObject:[self choiceLinkNamed:@"字体样式" key:@"FontStyle"]];
    [items addObject:[self buttonNamed:@"文字颜色" action:@selector(chooseTextColor)]];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"背景"]];
    [items addObject:[self preferenceNamed:@"启用背景颜色" key:@"EnabledBackgroundColor" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self buttonNamed:@"背景颜色" action:@selector(chooseBackgroundColor)]];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"上滑背景"]];
    [items addObject:[self preferenceNamed:@"启用上滑背景颜色" key:@"EnabledSwipeUpBackgroundColor" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self buttonNamed:@"上滑背景颜色" action:@selector(chooseSwipeUpBackgroundColor)]];

    PSSpecifier *scope = [PSSpecifier groupSpecifierWithName:@"生效范围"];
    [scope setProperty:@"打开「仅指定 App 生效」后，只有下面列表里勾选的 App 在横屏时才显示横屏块，其它 App 一律不显示（竖屏本来就不显示）。桌面和锁屏也一律不显示——iPhone 桌面不支持横屏，但把手机横过来时插件仍会算出横屏，所以这里专门把它们排除掉。名单为空＝全部不显示，所以打开开关后请马上在「选择 App…」里勾上要用的 App。勾选后即时生效，不用注销。"
                forKey:PSFooterTextGroupKey];
    [items addObject:scope];
    [items addObject:[self preferenceNamed:@"仅指定 App 生效" key:@"LandscapeAppFilterEnabled" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self buttonNamed:[self landscapeAppsButtonTitle] action:@selector(chooseLandscapeApps)]];

    PSSpecifier *landscape = [PSSpecifier groupSpecifierWithName:@"横屏块"];
    [landscape setProperty:@"横屏块固定单排显示（CPU 指标 + 电池温度 + 时间 + 电量在同一行），贴在屏幕最上方居中；竖屏自动隐藏。CPU 默认显示实时占用率——iOS 不开放真正的瞬时主频，读到的\"最高频率\"在部分机型上并不可信（会把别的频率表读成 CPU 频率），想要看的话可以在下面切换。"
                    forKey:PSFooterTextGroupKey];
    [items addObject:landscape];
    [items addObject:[self preferenceNamed:@"显示正在播放的音乐" key:@"LandscapeMusic" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"时间前显示 CPU 与电池温度" key:@"LandscapeMetrics" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"CPU 显示占用率（关＝芯片最高频率）" key:@"LandscapeMetricsUsage" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"横屏块自定义背景色" key:@"LandscapeCustomBackground" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self buttonNamed:@"横屏块背景颜色" action:@selector(chooseLandscapeBackgroundColor)]];

    PSSpecifier *musicFooter = [PSSpecifier groupSpecifierWithName:@"播放控制"];
    [musicFooter setProperty:@"边玩游戏边听歌时，横屏块会接上「♪ 歌名 · 歌手」。点一下横屏块（或双指同时点一下）弹出毛玻璃播放面板：封面、歌名、进度条，上一首 / 播放暂停 / 下一首，右下角可直接跳到正在播放的 App。\n\n面板展开后会自己收起：2 秒没有任何操作就自动缩回胶囊，按按钮 / 捏合缩放会重新计时；想立刻收起，直接点一下横屏胶囊即可。\n\n面板大小也可以在面板上用双指捏合调（松手即存，下面的滑块会同步成这个值），或者直接拖下面的「面板大小」滑块，范围 0.8 ~ 3.0：1.0 = 最小（156×76），1.8 = 默认（约 281×137），3.0 = 最大（约 468×228，接近最早那版）。"
                       forKey:PSFooterTextGroupKey];
    [items addObject:musicFooter];

    PSSpecifier *panelSize = [self preferenceNamed:@"面板大小" key:@"LandscapePanelScale"
                                      defaultValue:@1.8 cell:PSSliderCell];
    [panelSize setProperty:@0.8 forKey:PSControlMinimumKey];
    [panelSize setProperty:@3.0 forKey:PSControlMaximumKey];
    [panelSize setProperty:@YES forKey:@"showValue"];
    // Preferences 里滑块的左右文字标签；不同系统版本读的键不完全一样，三处都写，读不到就当没有。
    [panelSize setProperty:@"小" forKey:@"minLabel"];
    [panelSize setProperty:@"大" forKey:@"maxLabel"];
    [items addObject:panelSize];

    [items addObject:[PSSpecifier groupSpecifierWithName:@"操作"]];
    [items addObject:[self buttonNamed:@"恢复默认设置" action:@selector(onResetSettings)]];
    [items addObject:[self buttonNamed:@"注销桌面" action:@selector(onRespring)]];

    PSSpecifier *footer = [PSSpecifier emptyGroupSpecifier];
    [footer setProperty:@"Ntonia-PreferenceLoader 1.1-38" forKey:PSFooterTextGroupKey];
    [items addObject:footer];
    _specifiers = items;
    self.lastLandscapeAppCount = [self selectedLandscapeAppCount];
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    return PGReadValue(key, [specifier propertyForKey:PSDefaultValueKey]);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    PGWriteValue(key, value);

    // 打开「仅指定 App 生效」但一个 App 都没勾时，名单为空 = 全部不显示。
    // 这时候直接把选择页推上来，省得用户对着"什么都不显示了"发愣。
    if ([key isEqualToString:@"LandscapeAppFilterEnabled"] && [value boolValue]) {
        if ([self selectedLandscapeAppCount] == 0) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf chooseLandscapeApps];
            });
        }
    }
}

/// 「选择 App…（已选 N）」—— 一眼能看出名单里到底有没有东西。
- (NSString *)landscapeAppsButtonTitle {
    NSUInteger count = [self selectedLandscapeAppCount];
    if (count == 0) return @"选择 App…（一个都没选）";
    return [NSString stringWithFormat:@"选择 App…（已选 %lu 个）", (unsigned long)count];
}

- (NSUInteger)selectedLandscapeAppCount {
    id value = PGReadValue(@"LandscapeAppAllowList", @[]);
    return [value isKindOfClass:[NSArray class]] ? [(NSArray *)value count] : 0;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // 从选择页回来时刷新按钮标题（"已选 N 个"）。只在数量变了才重建，避免整页闪一下。
    // 第一次进来时 specifiers 还没建，取一次会顺带把基准值记上，不会重复刷新。
    if (self.specifiers.count == 0) return;
    NSUInteger count = [self selectedLandscapeAppCount];
    if (count != self.lastLandscapeAppCount) {
        self.lastLandscapeAppCount = count;
        [self reloadSpecifiers];
    }
}

- (UIColor *)colorForHex:(NSString *)hex fallback:(UIColor *)fallback {
    NSString *clean = [[hex ?: @"" stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (clean.length != 6) return fallback;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return fallback;
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0 alpha:1.0];
}

- (NSString *)hexForColor:(UIColor *)color {
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"#FFFFFF";
    return [NSString stringWithFormat:@"#%02lX%02lX%02lX",
            lround(red * 255.0), lround(green * 255.0), lround(blue * 255.0)];
}

- (void)showColorPickerForKey:(NSString *)key fallback:(UIColor *)fallback {
    self.activeColorKey = key;
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)PGDomain);
    NSString *stored = CFBridgingRelease(value);
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.delegate = self;
    picker.supportsAlpha = NO;
    picker.selectedColor = [self colorForHex:stored fallback:fallback];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseTextColor {
    [self showColorPickerForKey:@"TextColor" fallback:UIColor.whiteColor];
}

- (void)chooseBackgroundColor {
    [self showColorPickerForKey:@"BackgroundColor"
                       fallback:[UIColor colorWithRed:0 green:0.75 blue:1 alpha:1]];
}

- (void)chooseSwipeUpBackgroundColor {
    [self showColorPickerForKey:@"SwipeUpBackgroundColor"
                       fallback:[UIColor colorWithRed:0 green:0.68 blue:1 alpha:1]];
}

/// 选横屏块专属背景色时顺手把开关打开 —— 否则用户挑完颜色却看不出任何变化。
- (void)chooseLandscapeBackgroundColor {
    PGWriteValue(@"LandscapeCustomBackground", @YES);
    [self reloadSpecifiers];
    [self showColorPickerForKey:@"LandscapeBackgroundColor"
                       fallback:[UIColor colorWithRed:0 green:0.75 blue:1 alpha:1]];
}

- (void)chooseLandscapeApps {
    PGAppSelectionController *controller = [[PGAppSelectionController alloc] init];
    UINavigationController *navigation = self.navigationController;
    if (navigation) {
        [navigation pushViewController:controller animated:YES];
        return;
    }
    // 极少数情况下设置页不在导航栈里，兜底用模态。
    UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:controller];
    wrapper.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:wrapper animated:YES completion:nil];
}

- (void)storeSelectedColor:(UIColor *)color {
    if (!self.activeColorKey.length) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)self.activeColorKey,
                             (__bridge CFPropertyListRef)[self hexForColor:color],
                             (__bridge CFStringRef)PGDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)PGDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), PGChanged,
                                         NULL, NULL, YES);
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously {
    [self storeSelectedColor:color];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    [self storeSelectedColor:viewController.selectedColor];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self storeSelectedColor:viewController.selectedColor];
    self.activeColorKey = nil;
}

- (void)onResetSettings {
    NSArray *keys = @[@"EnabledPerfectGrabber", @"VibrationFeedback", @"ShowOnSwipeUp", @"LandscapeAlwaysOn",
                      @"LandscapeMusic", @"LandscapeMetrics", @"LandscapeMetricsUsage", @"LandscapeCustomBackground", @"LandscapeBackgroundColor",
                      @"LandscapeAppFilterEnabled", @"LandscapeAppAllowList", @"LandscapePanelScale",
                      @"Disable24H", @"ChargingIcon",
                      @"TwoLine", @"TextColor", @"GrabberStyle", @"FontSize", @"FontStyle",
                      @"EnabledBackgroundColor", @"BackgroundColor",
                      @"EnabledSwipeUpBackgroundColor", @"SwipeUpBackgroundColor"];
    for (NSString *key in keys) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)PGDomain);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)PGDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), PGChanged,
                                         NULL, NULL, YES);
    [self reloadSpecifiers];
}

- (NSString *)jailbreakRoot {
    NSString *executable = [NSBundle bundleForClass:self.class].executablePath;
    NSRange marker = [executable rangeOfString:@"/Library/PreferenceBundles/"];
    return marker.location == NSNotFound ? @"" : [executable substringToIndex:marker.location];
}

- (void)onRespring {
    NSString *root = [self jailbreakRoot];
    NSArray<NSString *> *candidates = @[
        [root stringByAppendingPathComponent:@"usr/bin/sbreload"],
        [root stringByAppendingPathComponent:@"usr/bin/killall"],
        @"/usr/bin/sbreload", @"/usr/bin/killall"
    ];
    for (NSString *path in candidates) {
        if (access(path.fileSystemRepresentation, X_OK) != 0) continue;
        pid_t pid = 0;
        BOOL killall = [path.lastPathComponent isEqualToString:@"killall"];
        char *const sbreloadArgs[] = {(char *)path.fileSystemRepresentation, NULL};
        char *const killallArgs[] = {(char *)path.fileSystemRepresentation, "-9", "SpringBoard", NULL};
        posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL,
                    killall ? killallArgs : sbreloadArgs, environ);
        return;
    }
}

@end
