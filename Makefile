FINALPACKAGE=1
THEOS_PACKAGE_SCHEME=rootless
ARCHS = arm64e
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ExposureControl
ExposureControl_FILES = Tweak.x
ExposureControl_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"

include $(THEOS_MAKE_PATH)/aggregate.mk
