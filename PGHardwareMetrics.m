#import "PGHardwareMetrics.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <string.h>
#import <math.h>

/// 日志统一由插件入口提供。
extern void PGDebugLog(NSString *format, ...);

/// 最多统计 16 个核（A19 Pro 是 6 核，留足余量）。
#define PGMaxCPUCount 16
/// 每个核的计数槽：user / system / idle / nice。
#define PGCPUStateSlots CPU_STATE_MAX

#pragma mark - CPU 占用率

double PGCPUUsagePercent(void) {
    // 采样本身要 vm_allocate 一块内核缓冲区，别每帧调；胶囊刷新最快 0.25 秒一次，
    // 这里缓存 0.8 秒就够 —— 肉眼上依然是"实时跳动"的。
    static uint32_t previous[PGMaxCPUCount][PGCPUStateSlots];
    static natural_t previousCount = 0;
    static BOOL hasPrevious = NO;
    static double cachedPercent = NAN;
    static CFAbsoluteTime cachedAt = 0.0;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cachedAt > 0.0 && now - cachedAt < 0.8) return cachedPercent;

    natural_t cpuCount = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;
    kern_return_t result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                               &cpuCount, &info, &infoCount);
    if (result != KERN_SUCCESS || info == NULL || infoCount == 0) {
        // 沙箱/机型不支持时保持上一次的值（若是 NAN 就是"没有这一项"），别把界面刷成 0%。
        cachedAt = now;
        if (!isnan(cachedPercent)) cachedPercent = NAN;
        static BOOL loggedFailure = NO;
        if (!loggedFailure) {
            loggedFailure = YES;
            PGDebugLog(@"硬件指标: host_processor_info 失败（kern_return=%d），改用不了占用率", (int)result);
        }
        return NAN;
    }

    if (cpuCount > PGMaxCPUCount) cpuCount = PGMaxCPUCount;
    uint32_t current[PGMaxCPUCount][PGCPUStateSlots];
    memset(current, 0, sizeof(current));
    for (natural_t index = 0; index < cpuCount; index++) {
        for (int slot = 0; slot < PGCPUStateSlots; slot++) {
            current[index][slot] = (uint32_t)info[index * CPU_STATE_MAX + slot];
        }
    }
    // 这块内存是 host_processor_info 用 vm_allocate 给的，必须还回去，否则每次采样漏一页。
    vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(integer_t));

    double percent = NAN;
    if (hasPrevious && previousCount == cpuCount) {
        uint64_t busyTicks = 0;
        uint64_t totalTicks = 0;
        for (natural_t index = 0; index < cpuCount; index++) {
            for (int slot = 0; slot < PGCPUStateSlots; slot++) {
                // tick 是 32 位且会回绕，先做无符号减法再按有符号解释，回绕也得到正确增量。
                int32_t delta = (int32_t)(current[index][slot] - previous[index][slot]);
                if (delta <= 0) continue;
                totalTicks += (uint64_t)delta;
                if (slot != CPU_STATE_IDLE) busyTicks += (uint64_t)delta;
            }
        }
        if (totalTicks > 0) {
            percent = (double)busyTicks / (double)totalTicks * 100.0;
            if (percent < 0.0) percent = 0.0;
            if (percent > 100.0) percent = 100.0;
        }
    }

    memcpy(previous, current, sizeof(current));
    previousCount = cpuCount;
    hasPrevious = YES;

    cachedPercent = percent;
    cachedAt = now;
    return percent;
}

#pragma mark - 电池温度

/// 不同机型/系统的 Temperature 单位不一样（0.01℃、0.1℃、甚至开尔文），
/// 逐个换算，取第一个落在"手机可能出现的温度"区间里的。
static double PGPlausibleCelsius(double raw) {
    double candidates[4] = {
        raw / 100.0,             // 0.01℃（iOS 上最常见）
        raw / 10.0,              // 0.1℃ / 0.1K
        raw,                     // 已经是℃
        raw / 1000.0 - 273.15    // 毫开尔文
    };
    for (int index = 0; index < 4; index++) {
        double celsius = candidates[index];
        if (celsius > 5.0 && celsius < 95.0) return celsius;
    }
    return NAN;
}

static double PGReadTemperatureFromService(NSString *className) {
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching(className.UTF8String));
    if (!service) return NAN;

    double result = NAN;
    for (NSString *key in @[@"Temperature", @"VirtualTemperature"]) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key,
                                                          kCFAllocatorDefault, 0);
        if (!value) continue;
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double raw = 0.0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &raw)) {
                result = PGPlausibleCelsius(raw);
            }
        }
        CFRelease(value);
        if (!isnan(result)) break;
    }

    IOObjectRelease(service);
    return result;
}

double PGBatteryTemperatureCelsius(void) {
    static BOOL loggedFailure = NO;
    for (NSString *name in @[@"AppleSmartBattery", @"AppleARMPMUCharger", @"IOPMPowerSource"]) {
        double celsius = PGReadTemperatureFromService(name);
        if (!isnan(celsius)) return celsius;
    }
    if (!loggedFailure) {
        loggedFailure = YES;
        PGDebugLog(@"硬件指标: 读不到电池温度（IOKit 三个服务都没有 Temperature）");
    }
    return NAN;
}
