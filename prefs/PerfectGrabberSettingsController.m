#import "PerfectGrabberSettingsController.h"
#import <Preferences/PSSpecifier.h>
#import <math.h>
#import <spawn.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

extern char **environ;

static NSString *const PGDomain = @"com.netskao.perfectgrabber";
static CFStringRef const PGChanged = CFSTR("com.netskao.perfectgrabber.settingschanged");
static id PGReadValue(NSString *key, id fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)PGDomain);
    return CFBridgingRelease(value) ?: fallback;
}
static void PGPostChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), PGChanged,
                                         NULL, NULL, YES);
}
static void PGWriteValue(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)PGDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)PGDomain);
    // 滑块打开 continuous 之后每秒会写几十次，通知合并到 100ms 一次，
    // 否则 SpringBoard 会跟着每秒重排几十次卡片，反而卡。
    static CFTimeInterval lastPost = 0.0;
    static BOOL postScheduled = NO;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastPost >= 0.10) { lastPost = now; PGPostChanged(); return; }
    if (postScheduled) return;
    postScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        postScheduled = NO;
        lastPost = CACurrentMediaTime();
        PGPostChanged();
    });
}

@interface PerfectGrabberSettingsController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *activeColorKey;
@property (nonatomic, strong) UISelectionFeedbackGenerator *sliderHaptics;
@end

@implementation PerfectGrabberSettingsController


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

- (PSSpecifier *)buttonNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL
                                                            detail:Nil cell:PSButtonCell edit:Nil];
    specifier.buttonAction = action;
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];
    PSSpecifier *main = [PSSpecifier groupSpecifierWithName:@"顶部播放器卡片"];
    [main setProperty:@"从顶部下拉呼出。时间、电量、温度与 CPU 常显；收起态显示曲目信息，长按在同一卡片中展开歌词/进度/控制。右上箭头手动收起/展开；面板收起时卡片随系统消失。联网查歌词默认关闭，开启后只上传歌名/歌手给 LRCLIB。" forKey:PSFooterTextGroupKey];
    [items addObject:main];
    [items addObject:[self preferenceNamed:@"启用卡片" key:@"EnabledPerfectGrabber" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"震动反馈" key:@"VibrationFeedback" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"使用12小时制" key:@"Disable24H" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"显示充电图标" key:@"ChargingIcon" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"长按显示播放控制" key:@"LongPressControls" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"联网查询歌词（只发送歌名/歌手；关闭则不联网）" key:@"LyricsLookupEnabled" defaultValue:@NO cell:PSSwitchCell]];

    NSArray<NSDictionary *> *sliderOptions = @[
        @{@"name":@"卡片宽度", @"key":@"CardWidth", @"value":@460.0, @"min":@300.0, @"max":@800.0, @"help":@"调整顶部卡片横向宽度；超出屏幕时自动限制在安全范围内。"},
        @{@"name":@"卡片整体大小", @"key":@"CardScale", @"value":@1.0, @"min":@0.7, @"max":@1.6, @"help":@"同步缩放卡片内容、图标及收起态尺寸。"},
        @{@"name":@"展开态卡片高度", @"key":@"CardHeightScale", @"value":@1.0, @"min":@0.7, @"max":@1.6, @"help":@"单独调整展开播放区高度。系统下拉面板空间有限，设备上可能裁剪。"},
        @{@"name":@"字体大小", @"key":@"FontSize", @"value":@15.0, @"min":@9.0, @"max":@24.0, @"help":@"调整时间、状态和歌曲信息的文字大小。"},
        @{@"name":@"字体粗细", @"key":@"FontWeight", @"value":@0.6, @"min":@0.0, @"max":@1.0, @"help":@"从纤细到粗体；影响时间、状态和曲目信息。"},
        @{@"name":@"毛玻璃强度", @"key":@"CardBlur", @"value":@0.82, @"min":@0.0, @"max":@1.0, @"help":@"调整卡片背后模糊效果的强弱；数值越大越明显。"},
        @{@"name":@"背景透明度", @"key":@"CardOpacity", @"value":@0.32, @"min":@0.05, @"max":@1.0, @"help":@"调整卡片毛玻璃上方深色叠底的不透明程度；数值越大底色越实。"},
        @{@"name":@"卡片圆角", @"key":@"CardCornerRadius", @"value":@34.0, @"min":@0.0, @"max":@48.0, @"help":@"调整卡片四角的圆弧半径；超过卡片高度一半时会自动按一半显示（收起态因此看是胶囊）。"}
    ];
    for (NSDictionary *option in sliderOptions) {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
        [group setProperty:option[@"help"] forKey:PSFooterTextGroupKey];
        [items addObject:group];
        PSSpecifier *slider = [self preferenceNamed:option[@"name"] key:option[@"key"] defaultValue:option[@"value"] cell:PSSliderCell];
        [slider setProperty:option[@"min"] forKey:PSControlMinimumKey];
        [slider setProperty:option[@"max"] forKey:PSControlMaximumKey];
        [items addObject:slider];
    }
    NSArray *cornerStyleNames = @[@"统一圆角", @"收起胶囊", @"全部胶囊", @"小圆角"];
    NSInteger cornerStyle = MAX(0, MIN(3, [PGReadValue(@"CornerStyle", @0) integerValue]));
    [items addObject:[self buttonNamed:[NSString stringWithFormat:@"圆角样式：%@（点击切换）", cornerStyleNames[cornerStyle]]
                                action:@selector(cycleCornerStyle)]];
    NSArray *backgroundNames = @[@"磨砂", @"毛玻璃", @"高斯模糊"];
    NSInteger backgroundIndex = MAX(0, MIN(2, [PGReadValue(@"BackgroundMode", @1) integerValue]));
    [items addObject:[self buttonNamed:[NSString stringWithFormat:@"背景模式：%@（点击切换）", backgroundNames[backgroundIndex]] action:@selector(cycleBackgroundMode)]];
    [items addObject:[self buttonNamed:@"文字颜色" action:@selector(chooseTextColor)]];
    [items addObject:[PSSpecifier groupSpecifierWithName:@"操作"]];
    [items addObject:[self buttonNamed:@"恢复默认设置" action:@selector(onResetSettings)]];
    [items addObject:[self buttonNamed:@"注销桌面" action:@selector(onRespring)]];
    PSSpecifier *footer = [PSSpecifier emptyGroupSpecifier];
    [footer setProperty:@"PerfectGrabber 单卡播放器" forKey:PSFooterTextGroupKey];
    [items addObject:footer];
    _specifiers = items;
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:PSKeyNameKey];
    return PGReadValue(key, [specifier propertyForKey:PSDefaultValueKey]);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    PGWriteValue([specifier propertyForKey:PSKeyNameKey], value);
}

// PSSliderCell 默认只在松手时提交，拖动过程不发 valueChanged —— 这就是"松手才震"的根因。
// 这里把 slider 设成 continuous，并且按"格"触发 selection 触感：每跨一格响一次，
// 手感是逐格步进，而不是按时间节流（时间节流在慢速拖动时会漏格）。
static const void *PGSliderDetentsKey = &PGSliderDetentsKey;
static const void *PGSliderLastStepKey = &PGSliderLastStepKey;

- (UISelectionFeedbackGenerator *)sliderHaptics {
    if (!_sliderHaptics) _sliderHaptics = [UISelectionFeedbackGenerator new];
    return _sliderHaptics;
}

- (BOOL)vibrationEnabled {
    return [PGReadValue(@"VibrationFeedback", @YES) boolValue];
}

- (void)settingsSliderBegan:(UISlider *)slider {
    objc_setAssociatedObject(slider, PGSliderLastStepKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.sliderHaptics prepare];
}

- (void)settingsSliderChanged:(UISlider *)slider {
    if (![self vibrationEnabled]) return;
    NSInteger detents = [objc_getAssociatedObject(slider, PGSliderDetentsKey) integerValue];
    if (detents < 2) detents = 30;
    CGFloat span = slider.maximumValue - slider.minimumValue;
    if (span <= 0.0) return;
    NSInteger step = (NSInteger)floor((slider.value - slider.minimumValue) / span * (CGFloat)detents);
    NSNumber *last = objc_getAssociatedObject(slider, PGSliderLastStepKey);
    if (last && last.integerValue == step) return;
    objc_setAssociatedObject(slider, PGSliderLastStepKey, @(step), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.sliderHaptics selectionChanged];
    [self.sliderHaptics prepare];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:cell];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:UISlider.class]) {
            UISlider *slider = (UISlider *)view;
            // 关键：continuous = YES，拖动过程中才发 valueChanged。
            slider.continuous = YES;
            id specifier = nil;
            @try { specifier = [cell valueForKey:@"specifier"]; } @catch (__unused NSException *e) { specifier = nil; }
            NSInteger detents = 30;
            if (specifier) {
                CGFloat minimum = [[specifier propertyForKey:PSControlMinimumKey] doubleValue];
                CGFloat maximum = [[specifier propertyForKey:PSControlMaximumKey] doubleValue];
                if (maximum > minimum) detents = 40;
            }
            objc_setAssociatedObject(slider, PGSliderDetentsKey, @(detents), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [slider removeTarget:self action:@selector(settingsSliderChanged:) forControlEvents:UIControlEventValueChanged];
            [slider addTarget:self action:@selector(settingsSliderChanged:) forControlEvents:UIControlEventValueChanged];
            [slider removeTarget:self action:@selector(settingsSliderBegan:) forControlEvents:UIControlEventTouchDown];
            [slider addTarget:self action:@selector(settingsSliderBegan:) forControlEvents:UIControlEventTouchDown];
            continue;
        }
        [pending addObjectsFromArray:view.subviews];
    }
}

- (UIColor *)colorForHex:(NSString *)hex fallback:(UIColor *)fallback {
    NSString *clean = [[hex ?: @"" stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (clean.length != 6 && clean.length != 8) return fallback;
    unsigned long long rgba = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexLongLong:&rgba] || !scanner.isAtEnd) return fallback;
    CGFloat alpha = clean.length == 8 ? ((rgba >> 24) & 0xff) / 255.0 : 1.0;
    return [UIColor colorWithRed:((rgba >> 16) & 0xff) / 255.0
                           green:((rgba >> 8) & 0xff) / 255.0
                            blue:(rgba & 0xff) / 255.0 alpha:alpha];
}

- (NSString *)hexForColor:(UIColor *)color {
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"#FFFFFF";
    return [NSString stringWithFormat:@"#%02lX%02lX%02lX%02lX",
            lround(alpha * 255.0), lround(red * 255.0), lround(green * 255.0), lround(blue * 255.0)];
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

- (void)cycleCornerStyle {
    NSInteger current = [PGReadValue(@"CornerStyle", @0) integerValue];
    PGWriteValue(@"CornerStyle", @((current + 1) % 4));
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)cycleBackgroundMode {
    NSInteger current = [PGReadValue(@"BackgroundMode", @1) integerValue];
    NSInteger next = (current + 1) % 3;
    PGWriteValue(@"BackgroundMode", @(next));
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)chooseTextColor {
    [self showColorPickerForKey:@"TextColor" fallback:UIColor.whiteColor];
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
    NSArray *keys = @[@"EnabledPerfectGrabber", @"VibrationFeedback", @"Disable24H", @"ChargingIcon",
                      @"LongPressControls", @"LyricsLookupEnabled", @"FontSize", @"FontWeight", @"TextColor", @"CardWidth", @"CardScale", @"CardHeightScale",
                      @"CardBlur", @"CardOpacity", @"CardCornerRadius", @"CornerStyle", @"BackgroundMode"];
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
