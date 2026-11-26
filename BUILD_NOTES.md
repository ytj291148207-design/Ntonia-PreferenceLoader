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

## 打包

macOS GitHub Actions 出 rootless 与 roothide 两种包，命令不变：

```bash
make clean && make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
./roothide-repack.sh packages/*rootless.deb dist/xxx_roothide.deb
```
