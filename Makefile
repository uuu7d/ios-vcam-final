THEOS_PACKAGE_SCHEME = rootless
TARGET = iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VirtualCamPro
VirtualCamPro_FILES = Tweak.x AVAssetStreamAdapter.m AntiDetection.x RuntimeProtection.x
VirtualCamPro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -O3 -fvisibility=hidden -ffunction-sections -fdata-sections
VirtualCamPro_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo QuartzCore CoreGraphics CoreImage Foundation ImageIO MobileCoreServices
VirtualCamPro_LDFLAGS = -undefined dynamic_lookup -Wl,-dead_strip
VirtualCamPro_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
