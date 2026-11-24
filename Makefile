ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PerfectGrabber
PerfectGrabber_FILES = Tweak.xm PerfectGrabberPreferences.m PGGrabberOverlayView.m PGGrabberHUDView.m PGGrabberLandscapeBar.m PGNowPlaying.m PGHardwareMetrics.m
PerfectGrabber_CFLAGS = -fobjc-arc
# MediaRemote 走 dlopen/dlsym 运行时加载，不写进 FRAMEWORKS（SDK 里没有它的 stub）。
# IOKit 用来读电池温度与 pmgr 的频率表。
PerfectGrabber_FRAMEWORKS = Foundation UIKit AudioToolbox CoreMotion IOKit

BUNDLE_NAME = PerfectGrabberSettings
PerfectGrabberSettings_FILES = prefs/PerfectGrabberSettingsController.m prefs/PGAppSelectionController.m
PerfectGrabberSettings_INSTALL_PATH = /Library/PreferenceBundles
PerfectGrabberSettings_FRAMEWORKS = Foundation UIKit
# -fno-autolink 必须有：#import <Preferences/PSListController.h> 会让 clang modules 自动
# 生成 LC_LINKER_OPTION "-framework Preferences"，而 iOS SDK 里没有这个 framework 的 stub，
# ld 直接报 "Could not find or use auto-linked framework 'Preferences'"。
# 关掉 autolink 后这些符号在设备上由 Preferences.framework 运行时提供（bundle 默认
# -undefined dynamic_lookup）。Foundation/UIKit 已显式写在 _FRAMEWORKS 里，不受影响。
PerfectGrabberSettings_CFLAGS = -fobjc-arc -fno-autolink
# PSListController / PSSpecifier / PS*Key 这些符号设备上由 Preferences.framework 提供，
# 链接期必须放行未定义符号，否则 ld 报 Undefined symbols。
PerfectGrabberSettings_LDFLAGS = -undefined dynamic_lookup
PerfectGrabberSettings_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
