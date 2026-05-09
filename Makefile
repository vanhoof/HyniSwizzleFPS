# HyniSwizzleFPS Makefile
#
# Builds a sideload-ready dylib at build/HyniSwizzleFPS.dylib. Drag this into
# Sideloadly's "Inject dylibs" list when re-signing the Minecraft IPA
# (alongside MCClient.dylib, HyniSign.dylib, and MaterialLoader.dylib).
#
# Targets:
#   make            Build sideload-ready dylib at build/HyniSwizzleFPS.dylib
#   make clean      Remove build artifacts
#
# Requires Theos: https://theos.dev/  (set $THEOS in your shell rc)

TARGET := iphone:clang:latest:14.0
ARCHS  := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME                 = HyniSwizzleFPS
HyniSwizzleFPS_FILES       = Tweak.x src/fps.m
HyniSwizzleFPS_FRAMEWORKS  = Foundation UIKit QuartzCore
HyniSwizzleFPS_CFLAGS      = -fobjc-arc -Isrc

include $(THEOS_MAKE_PATH)/tweak.mk

# Post-build: produce a sideload-ready copy with @executable_path install
# name and an ad-hoc signature. Sideloadly will re-sign with the user's
# cert when injecting into the IPA.
all::
	@mkdir -p build
	@cp .theos/obj/debug/HyniSwizzleFPS.dylib build/HyniSwizzleFPS.dylib
	@install_name_tool -id "@executable_path/HyniSwizzleFPS.dylib" build/HyniSwizzleFPS.dylib 2>/dev/null
	@codesign --remove-signature build/HyniSwizzleFPS.dylib 2>/dev/null || true
	@codesign -s - build/HyniSwizzleFPS.dylib 2>/dev/null
	@echo "==> Sideload-ready dylib: build/HyniSwizzleFPS.dylib"

clean::
	@rm -rf build
