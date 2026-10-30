TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
# THEOS_PACKAGE_SCHEME = rootless   # bỏ comment nếu jailbreak rootless (Dopamine...)
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AutoTap
AutoTap_FILES = Tweak.m
AutoTap_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AutoTap_FRAMEWORKS = UIKit QuartzCore CoreGraphics Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
