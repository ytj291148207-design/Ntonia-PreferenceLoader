#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CPU 总占用率（0–100）。失败返回 NAN。
/// 这是真正实时跳动的那一项：走 mach 的 host_processor_info 读每个核的
/// user/system/idle/nice 累计 tick，两次采样做差分。首次调用没有基线，返回 NAN，
/// 之后约 0.8 秒才有第一个值 —— 调用方按"拿不到就不显示"处理即可。
double PGCPUUsagePercent(void);

/// 当前 CPU 频率（GHz）。读不到返回 0。
/// ⚠️ 这一项不可靠：iOS 不向用户态暴露真正的"瞬时主频"，只能拿到芯片 DVFS 表里
/// 的最高档位。实测某些机型会把 GPU/缓存表的最大值读成 CPU 频率（A16 报出 4.29GHz），
/// 所以只在用户主动选择"显示频率"时才用，默认展示的是 PGCPUUsagePercent()。
double PGCPUCurrentFrequencyGHz(void);

/// 电池温度（摄氏度）。读不到返回 NAN。
double PGBatteryTemperatureCelsius(void);

NS_ASSUME_NONNULL_END
