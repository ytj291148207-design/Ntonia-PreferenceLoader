# 1.1-63 修复：方向、关闭按钮、进度条实时性

本版只改 `GrabberCardRootHide/GrabberCard`（RootHide 打包用的那套实现），顶层 `Tweak.xm` 旧实现未动。

## 1. 卡片方向不对

旧实现把卡片塞进 `SBGrabberTongue` 所在的面板窗口，用 `host.bounds` 竖屏坐标布局，并且
卡片固定画在锚点**下方**。横屏游戏里抓取条在左边缘，`y = 锚点.maxY + 8` 算出来放不下，
又被夹回屏幕左上角；自建的 `UIWindow` 还是按 `[UIScreen mainScreen].bounds` 建的，没有
`rootViewController`，横屏时窗口本身不会转，所以卡片看起来是横的/跑偏。

现在：

- 卡片挂在与原生面板**同一个 `UIWindowScene`** 的独立窗口（`initWithWindowScene:`），
  窗口带 `rootViewController`，`supportedInterfaceOrientations` 返回全方向，跟着设备转；
- 布局改成"离哪条边最近就贴哪一侧"：上边缘 → 画在下方，左边缘 → 画在右侧，
  右边缘 → 画在左侧，下边缘 → 画在上方，再按 `safeAreaInsets` 夹进屏幕；
- 旋转 / 状态栏变化都会重新对位。

## 2. 没有关闭按钮、卡片缩不回去

旧实现右上角是一个 `chevron.up` 按钮，白字白底放在浅色毛玻璃上几乎看不见，而且
`layoutSubviews` 每次都会把统计标签盖在它上面；卡片被 `frontDisplayDidChange:` 钩子
在切前台时直接移除，用户也没有稳定的关闭入口。

现在：

- 右上角常驻 **× 关闭按钮**（`PGCloseButton`，32pt，热区扩到 48pt），深色半透明底 + 白色
  图标，任何背景下都看得见；每次布局后 `bringSubviewToFront`，不再被标签盖住；
- 顶部小横条改成按钮，点一下即可**展开 / 收起**（长按仍然可用）；
- 关闭后卡片和覆盖窗口一起移除，下次下拉重新出现；不再在 `frontDisplayDidChange:` 里
  偷偷移除卡片。

## 3. 拉进度条不实时

- `PGProgressBar.setProgress:` 里直接重算 fill / knob 的 frame，不再等 `layoutSubviews`；
- 进度条纵向热区从 4pt 扩到 44pt，手指不用精确戳在细线上；
- 拖动时 `scrubbing = YES`，0.5 秒刷新不会把进度拉回去；松手 seek 后 1.2 秒内忽略
  播放器回传的旧进度（`_seekHoldUntil`），避免"拉完又弹回"；
- 显示进度不再完全依赖播放器回传：记录 `_lastSyncElapsed / _lastSyncTime`，按
  `playbackRate` 本地推算，播放器回传值与推算值差超过 1.5 秒才重新对齐，进度条每 0.5 秒
  平滑前进；暂停时速率归零，不会乱走。

## 4. 触摸穿透

旧的覆盖窗口 `userInteractionEnabled = YES` 且整屏只有一个卡片子视图，`UIWindow.hitTest`
会返回窗口本身 —— 面板收起后**整块屏幕都点不动**。现在：

- `PGOverlayWindow.hitTest` 只在命中卡片容器时返回视图，其余返回 `nil`；
- `PGCardContainer.hitTest` 只把落在卡片 `bounds` 内的点转给卡片。

## 5. 顺手修掉的问题

- **设置面板会把系统 API 换掉**：旧 `Settings.m` 给 `PSSpecifier` 加了个和系统方法同名的
  分类（只是参数类型不同），等于替换了整个 Preferences 进程里的
  `+preferenceSpecifierNamed:...cell:edit:`，别的面板传 `NSInteger` 进来会被当 Class 指针
  直接崩。改成 `pg_` 前缀的独立方法，内部仍调用系统 API。
- 滑杆把存进去的 `0`（圆角 0、透明度 0）当成"没设置"而回落默认值；改成 `stored != nil`。
- 时间格式分段默认显示"12 小时"但实际按 24 小时走：索引改成 1 = 24 小时，与布尔值一致。
- 偏好读取加内存缓存（`PGAllPrefs` 最多 0.25 秒 stat 一次文件），之前每取一个键都要
  读盘 + 解析 plist。
- 封面只在数据变化时重新解码，之前每 0.5 秒 `imageWithData:` 一次。
- 电量/温度/CPU 降到 2 秒采样一次；卡片不在窗口里时停掉定时器。
- 歌词 `NSURLSession` 用完 `invalidateAndCancel`，不再泄漏。

## 验证

本次只做了静态结构检查（括号配平、`@interface`/`@implementation`/`@end` 配对、调用点
一致性），**未在真机编译安装**。请在 iPhone 14 Pro Max / iOS 16.3.1 / Dopamine RootHide
上重新用 GitHub Actions 构建 `GrabberCard_1.1-63+roothide` 安装验证，重点看：

1. 横屏游戏里卡片是否贴在抓取条右侧且方向正确；
2. × 是否能关掉卡片、顶部横条是否能收起；
3. 拖动进度条是否跟手、松手是否弹回；
4. 卡片以外的区域能否正常操作游戏。

---

# 1.1-59 修复：内容被圆角裁掉

上一版把圆角做对了，但留白只按"行中心高度"算：胶囊顶部 y=3 处圆弧已经向内吃掉 10.9pt，
旧布局只让了 8.7pt，于是 `19:53` 的第一位数字、关闭按钮的方角都被弧线切掉；
展开态进度条的右端也贴着下弧线被削平。

- 新增 `PGFrameInset(minY, maxY, height, radius)`：一段内容按上下两端取较大的内缩，
  状态行、关闭按钮、封面、进度条全部改用它计算左右留白。
- 关闭按钮加 `clipsToBounds = YES`：半透明底色先裁成正圆，不再出现"方角伸到弧线外被切"的缺角。
- 宽卡片（非紧凑）布局同样接入 `sidePad`，首个数字和 × 不再贴边。
- 进度条按自身纵向区间让位，右端圆头完整。

---

# 1.1-58 四个问题的修复

## 1. 圆角：形状被"切平"、右端露出一块

根因有两层：

- `cornerRadius` 没有夹到半高。收起态卡片只有 44pt 高，半径滑到 34（再乘 cardScale 可能到 50+）时
  `CALayer` 的圆弧半径超过半高，连续曲率失效：四角的弧接不上，上下边被拉成直线，看起来就是
  "左上圆、左下尖、右边多一块"。现在统一由 `-pgEffectiveCornerRadius` 计算并 `MIN(radius, height/2)`。
- 圆角只设给了 `self.layer` 和 blur/tint，`closeButton`(20pt, r=13)、播放按钮(24pt, r=19) 也都超了半边长，
  同样会被切。现在按边长的一半设置。

另外状态行原来从 y=0 开始，胶囊端部的弧直接压在 `19:53` 上；现在按每行的中心高度算出
"圆角在这一行吃进去多少"，再补到 padding 上（`PGRadiusInset`）。

圆角策略新增 `CornerStyle`（0 统一 / 1 收起胶囊 / 2 全部半高 / 3 小圆角），默认按方案 B：统一 34pt，
收起态因为夹到半高自然是胶囊，展开是连续大圆角。

## 2. 滑块只在松手时震动

`PSSliderCell` 内部的 slider 默认只在提交时发 `valueChanged`（松手）。现在：

- `slider.continuous = YES`，拖动过程就发事件；
- 触感从"按时间节流 75ms"改成"按格"：0–1 区间切 40 格，跨一格 `UISelectionFeedbackGenerator`
  响一次，手感是逐格步进，慢拖也不会漏；
- 卡片里的进度条同样改成 30 格 selection 触感，不再用 `AudioServicesPlaySystemSound(1519)`；
- 连续拖动时 `CFPreferences` 写入不变，但 Darwin 通知合并到 100ms 一次，避免 SpringBoard 每秒重排几十次。

## 3. 长按呼不出播放控制 / 4. 卡片自己缩回去

这两个是同一个根因。旧实现把卡片塞进 `SBGrabberTongue._tongueContainer`，再把容器的 frame 改成卡片大小：

- SpringBoard 每次布局都会把 tongue 的 frame 重置回原生尺寸 → 卡片被压回 44pt（第 4 条）；
- tongue 自己带 `clipsToBounds`，展开多出来的高度被裁掉 → 看着像长按没反应（第 3 条）；
- tongue 的胶囊端头和 ∧ 箭头没被完全盖住 → 圆角外侧露出那块（第 1 条截图右侧）。

现在：

- 下拉时卡片作为 **窗口级独立视图**（`PGEdgeCardContainer`）挂在面板窗口最上层，不碰 tongue；
- 面板收起（`_willDismiss`）时把卡片搬进自建的 `PGOverlayWindow`（`UIWindowLevelAlert + 1`），
  层级高于 App，所以卡片会一直留在顶部，不会跟着面板消失；
- 悬浮窗的 `hitTest` 只放行卡片区域，其余点击全部穿透，不会挡到下面的 App；
- 移除了所有延时收起逻辑：只有点 × 或关掉总开关才移除；展开状态在换窗时保持不变；
- 长按 0.32s 触发，开始时有一次 medium 触感，`allowableMovement` 放宽到 24pt。

## 5. 封面占位符是一根竖条

`artworkFallbackLabel` 的字号写死 25pt，而 label 只有 18×18（收起态），字形被裁成一条竖线。
现在字号跟着封面尺寸走（`art * 0.62`）。

## 6. 字体大小滑杆把状态行撑爆

`configuredFontWithSize:` 之前忽略传进来的 size，直接把"字体大小"（默认 15）当字号用，
9pt 的状态行被撑成 15pt。现在按 `fontSize / 15` 的比例缩放各档字号，滑杆仍能整体放大缩小。

## 验证

静态检查：括号/结构配平、`@interface`/`@end`、`%hook`/`%end` 配对已过。
仍需在 iPhone 14 Pro Max / iOS 16.3.1 / Dopamine RootHide 上实机验证，日志在
`/var/mobile/Media/PerfectGrabber.log`（`[PG] present in ...` / `[PG] docked in ...` / `[PG] hide`）。

## 1.1-60 原生面板内嵌实验包（仅候选测试）

此改动依据用户选择，尝试把卡片放进原生面板窗口的内容视图树，不创建 alert-level 浮窗。下拉面板收起时卡片随之移除；该挂载点仍未在 iPhone 14 Pro Max / iOS 16.3.1 真机核实，可能被 SpringBoard 自身布局重排或裁剪，也可能并非抓取器私有面板窗口。展开高度滑块受到面板可用高度约束。

加入独立展开高度/字体粗细设置；长按展开可选；箭头按钮手动展开/收起；歌词通过 LRCLIB 网络查询，默认关闭，仅发送曲名/歌手，且尝试在关闭、切歌、面板收起时取消请求。歌词匹配、音乐 App 的 seek/按钮状态需真机验证。歌词服务返回歌词文本时应遵守其许可。

**实验候选，不是已验证修复版。**构建失败或设置页/面板异常时请先卸载，不要用旧包覆盖安装；先确认目标设备回滚路径。未安装/测试到 iPhone 14 Pro Max / iOS 16.3.1 / Dopamine RootHide。

## 1.1-62 截图反馈修订（待编译）

- 温度显示改为 ASCII `T xx°`，避免 ♨ 字形在设备上缺失；收起行重排时间/电量/温度/CPU，取消中间空白。
- 长按卡片展开后切到穿透触摸的高层覆盖窗口，隐藏原生胶囊的视觉图层，并在覆盖层中保持卡片展开。
- 长按开始先展开再转到高层、游戏触摸穿透窗口；松开不再自动收起，只有箭头按钮控制收放。
- 用户截图显示长按松手/原生面板 dismiss 会撤销卡片；本版将展开卡片迁到可穿透的 RootHide 高层窗口。其窗口、手势路由与横屏安全区坐标未真机验证。

在 iPhone 14 Pro Max、iOS 16.3.1、Dopamine RootHide 上未实测。仅在静态结构检查通过，需重新用 GitHub Actions 构建并实际安装后验证。

## 打包

macOS GitHub Actions 出 rootless 与 roothide 两种包，命令不变：

```bash
make clean && make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
./roothide-repack.sh packages/*rootless.deb dist/xxx_roothide.deb
```
