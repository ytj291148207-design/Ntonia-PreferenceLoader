#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CPU 总占用率（0–100）。失败返回 NAN。
/// 这是真正实时跳动的那一项：走 mach 的 host_processor_info 读每个核的
/// user/system/idle/nice 累计 tick，两次采样做差分。首次调用没有基线，返回 NAN，
/// 之后约 0.8 秒才有第一个值 —— 调用方按"拿不到就不显示"处理即可。
double PGCPUUsagePercent(void);

/// 电池温度（摄氏度）。读不到返回 NAN。
double PGBatteryTemperatureCelsius(void);

NS_ASSUME_NONNULL_END
