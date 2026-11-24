#import "PerfectGrabberSettingsController.h"
#import <Preferences/PSSpecifier.h>
#import <math.h>
#import <spawn.h>

extern char **environ;

static NSString *const PGDomain = @"com.netskao.perfectgrabber";
static CFStringRef const PGChanged = CFSTR("com.netskao.perfectgrabber.settingschanged");
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
    [main setProperty:@"从顶部下拉触发，系统面板收起后卡片仍贴在安全区上沿。长按同卡展开可点击的上一首、播放/暂停、下一首；再长按收回。歌词不联网，无系统歌词时显示“暂无歌词”。"
                forKey:PSFooterTextGroupKey];
    [items addObject:main];
    [items addObject:[self preferenceNamed:@"启用卡片" key:@"EnabledPerfectGrabber" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"震动反馈" key:@"VibrationFeedback" defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"使用12小时制" key:@"Disable24H" defaultValue:@NO cell:PSSwitchCell]];
    [items addObject:[self preferenceNamed:@"显示充电图标" key:@"ChargingIcon" defaultValue:@YES cell:PSSwitchCell]];

    PSSpecifier *sizeGroup = [PSSpecifier groupSpecifierWithName:@"卡片尺寸"];
    [sizeGroup setProperty:@"宽度会按屏幕可用范围限制；缩放调整卡片内容大小。"
                    forKey:PSFooterTextGroupKey];
    [items addObject:sizeGroup];
    NSArray<NSDictionary *> *sizeOptions = @[
        @{@"name":@"卡片宽度", @"key":@"CardWidth", @"value":@1000.0, @"min":@300.0, @"max":@1400.0},
        @{@"name":@"卡片缩放", @"key":@"CardScale", @"value":@1.0, @"min":@0.7, @"max":@1.6},
        @{@"name":@"字体大小", @"key":@"FontSize", @"value":@15.0, @"min":@9.0, @"max":@24.0}
    ];
    for (NSDictionary *option in sizeOptions) {
        PSSpecifier *slider = [self preferenceNamed:option[@"name"] key:option[@"key"] defaultValue:option[@"value"] cell:PSSliderCell];
        [slider setProperty:option[@"min"] forKey:PSControlMinimumKey];
        [slider setProperty:option[@"max"] forKey:PSControlMaximumKey];
        [slider setProperty:@YES forKey:@"showValue"];
        [items addObject:slider];
    }
    [items addObject:[self preferenceNamed:@"粗体字体" key:@"FontStyle" defaultValue:@0 cell:PSSwitchCell]];
    [items addObject:[self buttonNamed:@"文字颜色" action:@selector(chooseTextColor)]];

    PSSpecifier *glass = [PSSpecifier groupSpecifierWithName:@"毛玻璃背景"];
    [glass setProperty:@"调节毛玻璃可见强度、叠加底色透明度和卡片圆角。"
                 forKey:PSFooterTextGroupKey];
    [items addObject:glass];
    NSArray<NSDictionary *> *glassOptions = @[
        @{@"name":@"毛玻璃强度", @"key":@"CardBlur", @"value":@0.82, @"min":@0.0, @"max":@1.0},
        @{@"name":@"背景透明度", @"key":@"CardOpacity", @"value":@0.78, @"min":@0.05, @"max":@1.0},
        @{@"name":@"卡片圆角", @"key":@"CardCornerRadius", @"value":@22.0, @"min":@0.0, @"max":@48.0}
    ];
    for (NSDictionary *option in glassOptions) {
        PSSpecifier *slider = [self preferenceNamed:option[@"name"] key:option[@"key"] defaultValue:option[@"value"] cell:PSSliderCell];
        [slider setProperty:option[@"min"] forKey:PSControlMinimumKey];
        [slider setProperty:option[@"max"] forKey:PSControlMaximumKey];
        [slider setProperty:@YES forKey:@"showValue"];
        [items addObject:slider];
    }
    [items addObject:[self buttonNamed:@"毛玻璃底色和透明度" action:@selector(chooseBackgroundColor)]];
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
    picker.supportsAlpha = [key isEqualToString:@"CardTintColor"];
    picker.selectedColor = [self colorForHex:stored fallback:fallback];
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseTextColor {
    [self showColorPickerForKey:@"TextColor" fallback:UIColor.whiteColor];
}

- (void)chooseBackgroundColor {
    [self showColorPickerForKey:@"CardTintColor"
                       fallback:[UIColor colorWithWhite:0 alpha:0.12]];
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
                      @"FontSize", @"FontStyle", @"TextColor", @"CardWidth", @"CardScale",
                      @"CardBlur", @"CardOpacity", @"CardCornerRadius", @"CardTintColor"];
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
