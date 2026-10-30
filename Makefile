TARGET = iphone:clang:16.5:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME ?= roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = JianPan
JianPan_FILES = JianPan.m
JianPan_CFLAGS = -fobjc-arc -Wall
JianPan_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	install -d "$(THEOS_STAGING_DIR)/DEBIAN"
	install -m 0755 pkg-deb/postinst "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
	install -d "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	install -m 644 prefs/JianPan.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/JianPan.plist"
	install -d "$(THEOS_STAGING_DIR)/Library/JianPan/Themes"
	ldid -S -Cadhoc "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/JianPanPrefs.bundle/JianPanPrefs" && echo "signed prefs bundle"
