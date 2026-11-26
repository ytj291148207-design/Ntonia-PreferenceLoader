//
//  Settings.m
//  GrabberCard 设置面板
//

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "../PGPrefs.h"
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma mark - Preferences.framework 声明（SDK 内无该框架，运行时链接）

@class PSSpecifier;

@interface PSTableCell : UITableViewCell
@property (nonatomic, strong) PSSpecifier *specifier;
@end

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                  setter:(SEL)setter
                                  detail:(Class)detail
                                     cell:(Class)cell
                                     edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UITableViewController
- (NSArray *)specifiers;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
@end

@interface PSSwitchTableCell : PSTableCell
@end
@interface PSGroupCell : PSTableCell
@end

#pragma mark - 颜色

static UIColor *PGSettingsAccent(void) {
    return [UIColor colorWithRed:0.36 green:0.75 blue:1.0 alpha:1.0];
}

#pragma mark - 顶部头图

@interface PGHeaderCell : PSTableCell
@end

@implementation PGHeaderCell {
    CAGradientLayer *_gradient;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIImageView *_iconView;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _gradient = [CAGradientLayer layer];
        _gradient.colors = @[
            (id)[UIColor colorWithRed:0.16 green:0.22 blue:0.34 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.09 green:0.13 blue:0.22 alpha:1.0].CGColor,
        ];
        _gradient.startPoint = CGPointMake(0, 0);
        _gradient.endPoint = CGPointMake(1, 1);
        [self.contentView.layer addSublayer:_gradient];

        _iconView = [[UIImageView alloc] init];
        _iconView.image = [UIImage systemImageNamed:@"rectangle.stack.badge.play"];
        _iconView.tintColor = [UIColor colorWithRed:0.55 green:0.82 blue:1.0 alpha:1.0];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = @"GrabberCard";
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.text = @"游戏内下拉卡片 · 时间 / 电量 / 温度 / CPU / 音乐控制";
        _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
        _subtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        _subtitleLabel.numberOfLines = 0;
        [self.contentView addSubview:_subtitleLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradient.frame = self.contentView.bounds;
    _iconView.frame = CGRectMake(20, 22, 40, 40);
    _titleLabel.frame = CGRectMake(72, 24, self.contentView.bounds.size.width - 92, 30);
    _subtitleLabel.frame = CGRectMake(72, 58, self.contentView.bounds.size.width - 92, 36);
}

@end

#pragma mark - 分组标题

@interface PGGroupCell : PSTableCell
@end

@implementation PGGroupCell {
    UILabel *_label;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _label = [[UILabel alloc] init];
        _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _label.textColor = [UIColor colorWithRed:0.42 green:0.45 blue:0.50 alpha:1.0];
        [self.contentView addSubview:_label];
    }
    return self;
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    _label.text = [specifier propertyForKey:@"label"] ?: [specifier propertyForKey:@"title"];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _label.frame = CGRectMake(16, 2, self.contentView.bounds.size.width - 32, 26);
}

@end

#pragma mark - 滑块

@interface PGSliderCell : PSTableCell
@end

@implementation PGSliderCell {
    UILabel *_titleLabel;
    UILabel *_valueLabel;
    UISlider *_slider;
    NSString *_key;
    NSNumber *_minValue;
    NSNumber *_maxValue;
    NSNumber *_defaultValue;
    NSString *_suffix;
    BOOL _integer;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        _titleLabel.textColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
        [self.contentView addSubview:_titleLabel];

        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _valueLabel.textColor = PGSettingsAccent();
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];

        _slider = [[UISlider alloc] init];
        _slider.minimumTrackTintColor = PGSettingsAccent();
        [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_slider];
    }
    return self;
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];

    _key = [specifier propertyForKey:@"key"];
    _minValue = [specifier propertyForKey:@"min"] ?: @(0);
    _maxValue = [specifier propertyForKey:@"max"] ?: @(100);
    _defaultValue = [specifier propertyForKey:@"default"] ?: _minValue;
    _suffix = [specifier propertyForKey:@"suffix"] ?: @"";
    _integer = [[specifier propertyForKey:@"integer"] boolValue];

    _titleLabel.text = [specifier propertyForKey:@"label"] ?: [specifier propertyForKey:@"title"];

    _slider.minimumValue = [_minValue floatValue];
    _slider.maximumValue = [_maxValue floatValue];

    NSNumber *stored = PGGetPref(_key, nil);
    _slider.value = [stored floatValue] > 0 ? [stored floatValue] : [_defaultValue floatValue];
    [self updateValueLabel];
}

- (void)sliderChanged:(UISlider *)slider {
    CGFloat value = slider.value;
    if (_integer) value = round(value);
    PGSetPref(_key, @(_integer ? (NSInteger)value : value));
    PGPostPrefsChanged();
    [self updateValueLabel];
}

- (void)updateValueLabel {
    CGFloat value = _slider.value;
    if (_integer) {
        _valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)round(value), _suffix ?: @""];
    } else {
        _valueLabel.text = [NSString stringWithFormat:@"%.2f%@", value, _suffix ?: @""];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    _titleLabel.frame = CGRectMake(16, 8, width * 0.62, 22);
    _valueLabel.frame = CGRectMake(width - 16 - 120, 8, 120, 22);
    _slider.frame = CGRectMake(14, 34, width - 28, 34);
}

@end

#pragma mark - 分段选择

@interface PGSegmentCell : PSTableCell
@end

@implementation PGSegmentCell {
    UILabel *_titleLabel;
    UISegmentedControl *_control;
    NSString *_key;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        _titleLabel.textColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
        [self.contentView addSubview:_titleLabel];

        _control = [[UISegmentedControl alloc] init];
        [_control addTarget:self action:@selector(controlChanged:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_control];
    }
    return self;
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    _key = [specifier propertyForKey:@"key"];
    _titleLabel.text = [specifier propertyForKey:@"label"] ?: [specifier propertyForKey:@"title"];

    NSArray *titles = [specifier propertyForKey:@"titles"] ?: @[];
    [_control removeAllSegments];
    [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger idx, BOOL *stop) {
        [_control insertSegmentWithTitle:title atIndex:idx animated:NO];
    }];
    _control.selectedSegmentIndex = (NSInteger)PGGetInt(_key, 0);
}

- (void)controlChanged:(UISegmentedControl *)control {
    PGSetPref(_key, @(control.selectedSegmentIndex));
    PGPostPrefsChanged();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    _titleLabel.frame = CGRectMake(16, 6, width - 32, 20);
    _control.frame = CGRectMake(14, 32, width - 28, 32);
}

@end

#pragma mark - 按钮

@interface PGButtonCell : PSTableCell
@end

@implementation PGButtonCell {
    UIButton *_button;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _button = [UIButton buttonWithType:UIButtonTypeSystem];
        _button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _button.layer.cornerRadius = 12.0;
        _button.layer.masksToBounds = YES;
        [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_button];
    }
    return self;
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    NSString *title = [specifier propertyForKey:@"label"] ?: [specifier propertyForKey:@"title"];
    NSString *kind = [specifier propertyForKey:@"kind"];
    [_button setTitle:title forState:UIControlStateNormal];
    if ([kind isEqualToString:@"danger"]) {
        _button.backgroundColor = [UIColor colorWithRed:1.0 green:0.93 blue:0.94 alpha:1.0];
        [_button setTitleColor:[UIColor colorWithRed:0.85 green:0.20 blue:0.25 alpha:1.0] forState:UIControlStateNormal];
    } else {
        _button.backgroundColor = [UIColor colorWithRed:0.90 green:0.94 blue:1.0 alpha:1.0];
        [_button setTitleColor:PGSettingsAccent() forState:UIControlStateNormal];
    }
}

- (void)tapped {
    NSString *action = [self.specifier propertyForKey:@"action"];
    if (!action) return;
    SEL selector = NSSelectorFromString(action);
    id target = [self.specifier propertyForKey:@"target"];
    if (!target) return;
    if ([target respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(target, selector);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    _button.frame = CGRectMake(16, 8, width - 32, 44);
}

@end

#pragma mark - 开关

@interface PGSwitchCell : PSTableCell
@end

@implementation PGSwitchCell {
    UILabel *_titleLabel;
    UISwitch *_switch;
    NSString *_key;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        _titleLabel.textColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
        [self.contentView addSubview:_titleLabel];

        _switch = [[UISwitch alloc] init];
        _switch.onTintColor = PGSettingsAccent();
        [_switch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_switch];
    }
    return self;
}

- (void)setSpecifier:(PSSpecifier *)specifier {
    [super setSpecifier:specifier];
    _key = [specifier propertyForKey:@"key"];
    _titleLabel.text = [specifier propertyForKey:@"label"] ?: [specifier propertyForKey:@"title"];
    _switch.on = PGGetBool(_key, [[specifier propertyForKey:@"default"] boolValue]);
}

- (void)switchChanged:(UISwitch *)sender {
    PGSetPref(_key, @(sender.on));
    PGPostPrefsChanged();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    _titleLabel.frame = CGRectMake(16, 0, width - 16 - 51 - 32, self.contentView.bounds.size.height);
    _switch.frame = CGRectMake(width - 51 - 16, (self.contentView.bounds.size.height - 31) / 2.0, 51, 31);
}

@end

#pragma mark - 控制器

@interface GrabberCardSettingsController : PSListController
@end

@implementation GrabberCardSettingsController {
    NSArray *_cachedSpecifiers;
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        self.title = @"GrabberCard";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
}

- (NSArray *)specifiers {
    if (_cachedSpecifiers) return _cachedSpecifiers;

    NSMutableArray *specs = [NSMutableArray array];

    // MARK: 头部
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:@""
                                                     target:nil
                                                     setter:NULL
                                                     detail:nil
                                                       cell:[PGHeaderCell class]
                                                       edit:NULL]];

    // MARK: 总开关
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"启用插件"
                                                     target:nil setter:NULL detail:nil cell:[PGGroupCell class] edit:NULL]];
    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"在抓取卡片中显示 GrabberCard"
                                                          target:self
                                                          setter:@selector(setPreferenceValue:specifier:)
                                                          detail:nil
                                                            cell:[PGSwitchCell class]
                                                            edit:NULL];
    [enabled setProperty:@"enabled" forKey:@"key"];
    [enabled setProperty:@YES forKey:@"default"];
    [specs addObject:enabled];

    // MARK: 卡片外观
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"卡片外观"
                                                     target:nil setter:NULL detail:nil cell:[PGGroupCell class] edit:NULL]];

    [specs addObject:[self sliderWithName:@"卡片大小" key:@"cardScale" min:0.8 max:1.3 defaultValue:1.0 suffix:@"×" integer:NO]];
    [specs addObject:[self sliderWithName:@"卡片宽度" key:@"cardWidth" min:240 max:430 defaultValue:356 suffix:@" pt" integer:YES]];
    [specs addObject:[self sliderWithName:@"卡片高度" key:@"cardHeight" min:150 max:440 defaultValue:246 suffix:@" pt" integer:YES]];
    [specs addObject:[self sliderWithName:@"卡片圆角" key:@"cornerRadius" min:0 max:40 defaultValue:24 suffix:@" pt" integer:YES]];
    [specs addObject:[self sliderWithName:@"卡片透明度" key:@"opacity" min:0.2 max:1.0 defaultValue:0.92 suffix:@"" integer:NO]];

    [specs addObject:[self segmentWithName:@"背景质感" key:@"backgroundStyle" titles:@[@"毛玻璃", @"磨砂", @"高斯模糊"]]];

    // MARK: 信息显示
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"信息显示"
                                                     target:nil setter:NULL detail:nil cell:[PGGroupCell class] edit:NULL]];
    [specs addObject:[self segmentWithName:@"时间格式" key:@"use24Hour" titles:@[@"24 小时", @"12 小时"]]];
    [specs addObject:[self sliderWithName:@"字体大小" key:@"fontScale" min:0.8 max:1.4 defaultValue:1.0 suffix:@"×" integer:NO]];
    [specs addObject:[self segmentWithName:@"字体粗细" key:@"fontWeight" titles:@[@"常规", @"中等", @"半粗", @"加粗"]]];

    // MARK: 音乐
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"音乐"
                                                     target:nil setter:NULL detail:nil cell:[PGGroupCell class] edit:NULL]];

    PSSpecifier *longPress = [PSSpecifier preferenceSpecifierNamed:@"长按卡片显示进度条与控制"
                                                            target:self
                                                            setter:@selector(setPreferenceValue:specifier:)
                                                            detail:nil
                                                              cell:[PGSwitchCell class]
                                                              edit:NULL];
    [longPress setProperty:@"longPressControls" forKey:@"key"];
    [longPress setProperty:@YES forKey:@"default"];
    [specs addObject:longPress];

    PSSpecifier *lyrics = [PSSpecifier preferenceSpecifierNamed:@"显示歌词"
                                                          target:self
                                                          setter:@selector(setPreferenceValue:specifier:)
                                                          detail:nil
                                                            cell:[PGSwitchCell class]
                                                            edit:NULL];
    [lyrics setProperty:@"showLyrics" forKey:@"key"];
    [lyrics setProperty:@YES forKey:@"default"];
    [specs addObject:lyrics];

    // MARK: 触感反馈
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"触感反馈"
                                                     target:nil setter:NULL detail:nil cell:[PGGroupCell class] edit:NULL]];

    PSSpecifier *presentHaptic = [PSSpecifier preferenceSpecifierNamed:@"下拉卡片时震动"
                                                                target:self
                                                                setter:@selector(setPreferenceValue:specifier:)
                                                                detail:nil
                                                                  cell:[PGSwitchCell class]
                                                                  edit:NULL];
    [presentHaptic setProperty:@"presentHaptic" forKey:@"key"];
    [presentHaptic setProperty:@YES forKey:@"default"];
    [specs addObject:presentHaptic];

    PSSpecifier *sliderHaptic = [PSSpecifier preferenceSpecifierNamed:@"拖动进度条逐格震动"
                                                                target:self
                                                                setter:@selector(setPreferenceValue:specifier:)
                                                                detail:nil
                                                                  cell:[PGSwitchCell class]
                                                                  edit:NULL];
    [sliderHaptic setProperty:@"sliderHaptic" forKey:@"key"];
    [sliderHaptic setProperty:@YES forKey:@"default"];
    [specs addObject:sliderHaptic];

    // MARK: 操作
    [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"操作"
                                                     target:nil setter:NULL detail:nil cell:[PGGroupCell class] edit:NULL]];

    PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"恢复默认设置"
                                                         target:self
                                                         setter:NULL
                                                         detail:nil
                                                           cell:[PGButtonCell class]
                                                           edit:NULL];
    [reset setProperty:@"reset" forKey:@"action"];
    [reset setProperty:self forKey:@"target"];
    [reset setProperty:@"danger" forKey:@"kind"];
    [specs addObject:reset];

    PSSpecifier *respring = [PSSpecifier preferenceSpecifierNamed:@"注销 SpringBoard"
                                                           target:self
                                                           setter:NULL
                                                           detail:nil
                                                             cell:[PGButtonCell class]
                                                             edit:NULL];
    [respring setProperty:@"respring" forKey:@"action"];
    [respring setProperty:self forKey:@"target"];
    [specs addObject:respring];

    _cachedSpecifiers = [specs copy];
    return _cachedSpecifiers;
}

- (PSSpecifier *)sliderWithName:(NSString *)name
                            key:(NSString *)key
                            min:(CGFloat)min
                            max:(CGFloat)max
                    defaultValue:(CGFloat)defaultValue
                         suffix:(NSString *)suffix
                        integer:(BOOL)isInteger {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:nil setter:NULL detail:nil cell:[PGSliderCell class] edit:NULL];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:@(min) forKey:@"min"];
    [spec setProperty:@(max) forKey:@"max"];
    [spec setProperty:@(defaultValue) forKey:@"default"];
    [spec setProperty:suffix forKey:@"suffix"];
    [spec setProperty:@(isInteger) forKey:@"integer"];
    return spec;
}

- (PSSpecifier *)segmentWithName:(NSString *)name key:(NSString *)key titles:(NSArray<NSString *> *)titles {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:nil setter:NULL detail:nil cell:[PGSegmentCell class] edit:NULL];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:titles forKey:@"titles"];
    return spec;
}

#pragma mark - 读写

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key) return [super readPreferenceValue:specifier];
    id stored = PGGetPref(key, nil);
    if (stored) return stored;
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key) {
        PGSetPref(key, value);
        PGPostPrefsChanged();
    }
}

#pragma mark - 数据源（单 section 扁平列表，避免分组映射问题）

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.specifiers.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *specs = self.specifiers;
    if ((NSUInteger)indexPath.row >= specs.count) {
        return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"GrabberCardBlank"];
    }
    PSSpecifier *specifier = specs[indexPath.row];
    NSString *cellName = [specifier propertyForKey:@"cell"] ?: [specifier propertyForKey:@"cellType"];
    Class cellClass = cellName ? NSClassFromString(cellName) : Nil;
    if (!cellClass) cellClass = [UITableViewCell class];

    NSString *identifier = [NSString stringWithFormat:@"GrabberCard-%@", NSStringFromClass(cellClass)];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[cellClass alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    if ([cell respondsToSelector:@selector(setSpecifier:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(cell, @selector(setSpecifier:), specifier);
    }
    if ([cell isKindOfClass:[PGGroupCell class]]) {
        cell.separatorInset = UIEdgeInsetsMake(0, 10000, 0, 0);
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *specs = self.specifiers;
    if ((NSUInteger)indexPath.row >= specs.count) return 44.0;
    PSSpecifier *specifier = specs[indexPath.row];
    NSString *name = [specifier propertyForKey:@"cell"] ?: [specifier propertyForKey:@"cellType"];
    if ([name isEqualToString:@"PGHeaderCell"]) return 116.0;
    if ([name isEqualToString:@"PGSliderCell"]) return 76.0;
    if ([name isEqualToString:@"PGSegmentCell"]) return 82.0;
    if ([name isEqualToString:@"PGGroupCell"]) return 34.0;
    if ([name isEqualToString:@"PGButtonCell"]) return 60.0;
    if ([name isEqualToString:@"PGSwitchCell"]) return 52.0;
    return 44.0;
}

#pragma mark - 操作

- (void)reset {
    PGRemoveAllPrefs();
    PGPostPrefsChanged();
    _cachedSpecifiers = nil;
    [self.tableView reloadData];
}

- (void)respring {
    Class serviceClass = NSClassFromString(@"FBSystemService");
    if (serviceClass) {
        id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, @selector(sharedInstance));
        if (service && [service respondsToSelector:@selector(shutdownAndReboot)]) {
            ((void (*)(id, SEL))objc_msgSend)(service, @selector(shutdownAndReboot));
            return;
        }
    }

    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (handle) {
        void (*relaunch)(void) = (void (*)(void))dlsym(handle, "SBSRelaunchSpringBoard");
        if (relaunch) { relaunch(); return; }
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法自动注销"
                                                                   message:@"请在设备上手动注销 SpringBoard 使设置完全生效。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
