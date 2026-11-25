ifneq ($(ROOTFUL),1)
THEOS_PACKAGE_SCHEME = rootless
endif
FINALPACKAGE ?= 1
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Camera Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ExposureControl
ExposureControl_FILES = Tweak.x
ExposureControl_CFLAGS = -fobjc-arc
ifneq ($(DIAG),)
ExposureControl_CFLAGS += $(foreach d,$(DIAG),-D$(d))
endif
ifneq ($(EXP),)
ExposureControl_CFLAGS += $(foreach e,$(EXP),-DEXP_$(e))
endif

include $(THEOS_MAKE_PATH)/tweak.mk
