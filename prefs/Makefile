include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = JianPanPrefs
JianPanPrefs_FILES = RootListController.m
JianPanPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I.
JianPanPrefs_FRAMEWORKS = UIKit Foundation
JianPanPrefs_PRIVATE_FRAMEWORKS = Preferences
JianPanPrefs_INSTALL_PATH = /Library/PreferenceBundles
JianPanPrefs_RESOURCE_FILES = Resources/Root.plist Resources/Info.plist Resources/icon.png Resources/icon@2x.png Resources/icon@3x.png

include $(THEOS_MAKE_PATH)/bundle.mk
