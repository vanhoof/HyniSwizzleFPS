// fps.m — CADisplayLink swizzle that upgrades every link MCBE creates
// to the device's max refresh rate. Pure ObjC runtime work; no Logos
// %hook (which would pull in CydiaSubstrate and fail-load on non-jailbroken
// iOS), no MSHookFunction, no RWX page allocation.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include "fps.h"

#define LOG(fmt, ...) NSLog(@"[HyniSwizzleFPS] " fmt, ##__VA_ARGS__)

// Device's actual max refresh rate. 60 on standard iPad / iPad Air pre-M2 /
// iPad mini pre-A17, 120 on iPad Pro ProMotion and the new iPad Air/mini.
// Returns 60 as a fallback if mainScreen isn't available yet — first hook
// call may land before the UI is up, in which case we no-op rather than
// guess.
static NSInteger HSFPS_DeviceMax(void) {
    NSInteger m = UIScreen.mainScreen.maximumFramesPerSecond;
    return m > 0 ? m : 60;
}

// Saved originals, captured at swizzle-install time.
static CADisplayLink *(*g_orig_cadl_factory)(Class, SEL, id, SEL) = NULL;
static CADisplayLink *(*g_orig_uis_factory)(UIScreen *, SEL, id, SEL) = NULL;
static void (*g_orig_setPreferredFramesPerSecond)(CADisplayLink *, SEL, NSInteger) = NULL;
static void (*g_orig_setFrameInterval)(CADisplayLink *, SEL, NSInteger) = NULL;

// Apply our preferred frame rate range to a freshly-minted link. Apple's
// docs are explicit: if both preferredFrameRateRange and the legacy
// preferredFramesPerSecond / frameInterval are set, preferredFrameRateRange
// takes precedence. So we set it once at creation and trust it to win.
static void HSFPS_upgrade_link(CADisplayLink *link, const char *origin, id target, SEL sel) {
    NSInteger max = HSFPS_DeviceMax();
    if (link == nil || max <= 60) return;

    if (@available(iOS 15.0, *)) {
        link.preferredFrameRateRange = CAFrameRateRangeMake(60.0f, (float)max, (float)max);
    } else {
        link.preferredFramesPerSecond = max;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LOG(@"first display link upgraded via %s: target=%@ sel=%@ cap=%ld",
            origin, [target class], NSStringFromSelector(sel), (long)max);
    });
}

// +[CADisplayLink displayLinkWithTarget:selector:] — the canonical iOS 3.1+
// factory. MCBE 1.26.13 doesn't appear to use this path, but other libs in
// the process might.
static CADisplayLink *HSFPS_hook_cadl_factory(Class self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = g_orig_cadl_factory(self, _cmd, target, sel);
    HSFPS_upgrade_link(link, "+CADisplayLink", target, sel);
    return link;
}

// -[UIScreen displayLinkWithTarget:selector:] — instance method on UIScreen
// that internally constructs a CADisplayLink bound to that screen. Symbol
// dump of MCBE 1.26.13 shows mainScreen + displayLinkWithTarget:selector:
// + setFrameInterval: clustered together, which is the classic legacy-iOS
// pattern: [[UIScreen mainScreen] displayLinkWithTarget:self selector:...].
static CADisplayLink *HSFPS_hook_uis_factory(UIScreen *self, SEL _cmd, id target, SEL sel) {
    CADisplayLink *link = g_orig_uis_factory(self, _cmd, target, sel);
    HSFPS_upgrade_link(link, "-UIScreen", target, sel);
    return link;
}

static void HSFPS_hook_setPreferredFramesPerSecond(CADisplayLink *self, SEL _cmd, NSInteger fps) {
    NSInteger max = HSFPS_DeviceMax();
    if (max > 60 && fps > 0 && fps < max) {
        fps = max;
    }
    g_orig_setPreferredFramesPerSecond(self, _cmd, fps);
}

// -[CADisplayLink setFrameInterval:] — deprecated since iOS 10 but still
// supported. MCBE 1.26.13's iOS code path uses this. The legacy API caps at
// 60 Hz on ProMotion regardless of the value passed; the way to get higher
// is to set preferredFrameRateRange (which we already did at creation).
// Re-apply the modern range here as defense in depth, in case the legacy
// setter resets internal state.
static void HSFPS_hook_setFrameInterval(CADisplayLink *self, SEL _cmd, NSInteger interval) {
    g_orig_setFrameInterval(self, _cmd, interval);
    NSInteger max = HSFPS_DeviceMax();
    if (max > 60 && self != nil) {
        if (@available(iOS 15.0, *)) {
            self.preferredFrameRateRange = CAFrameRateRangeMake(60.0f, (float)max, (float)max);
        }
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LOG(@"setFrameInterval(%ld) intercepted; range re-applied", (long)interval);
    });
}

static bool HSFPS_swizzle_class(Class cls, SEL sel, IMP newImpl, void *origSlot) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return false;
    *(IMP *)origSlot = method_getImplementation(m);
    method_setImplementation(m, newImpl);
    return true;
}

static bool HSFPS_swizzle_instance(Class cls, SEL sel, IMP newImpl, void *origSlot) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return false;
    *(IMP *)origSlot = method_getImplementation(m);
    method_setImplementation(m, newImpl);
    return true;
}

int HSFPS_EffectiveCap(void) {
    NSInteger devMax = HSFPS_DeviceMax();
    if (devMax <= 60) return 60;

    // iPhone ProMotion is system-clamped to 60 unless the main app bundle's
    // Info.plist sets CADisableMinimumFrameDurationOnPhone = YES. The
    // swizzle's API call still succeeds in that case, so the only honest
    // signal that 120 will actually render is the plist key being present.
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        id v = [[NSBundle mainBundle] objectForInfoDictionaryKey:
                @"CADisableMinimumFrameDurationOnPhone"];
        if (![v isKindOfClass:[NSNumber class]] || ![v boolValue]) return 60;
    }
    return (int)devMax;
}

bool HSFPS_Init(void) {
    static bool installed = false;
    if (installed) return true;

    Class cadl = [CADisplayLink class];
    Class uis  = [UIScreen class];

    bool cadl_factory_ok = HSFPS_swizzle_class(cadl,
                                               @selector(displayLinkWithTarget:selector:),
                                               (IMP)HSFPS_hook_cadl_factory,
                                               &g_orig_cadl_factory);

    bool uis_factory_ok = HSFPS_swizzle_instance(uis,
                                                 @selector(displayLinkWithTarget:selector:),
                                                 (IMP)HSFPS_hook_uis_factory,
                                                 &g_orig_uis_factory);

    bool fps_setter_ok = HSFPS_swizzle_instance(cadl,
                                                @selector(setPreferredFramesPerSecond:),
                                                (IMP)HSFPS_hook_setPreferredFramesPerSecond,
                                                &g_orig_setPreferredFramesPerSecond);

    bool interval_setter_ok = HSFPS_swizzle_instance(cadl,
                                                     @selector(setFrameInterval:),
                                                     (IMP)HSFPS_hook_setFrameInterval,
                                                     &g_orig_setFrameInterval);

    LOG(@"hooks installed: cadl_factory=%s uis_factory=%s fps_setter=%s interval_setter=%s",
        cadl_factory_ok    ? "ok" : "FAILED",
        uis_factory_ok     ? "ok" : "FAILED",
        fps_setter_ok      ? "ok" : "FAILED",
        interval_setter_ok ? "ok" : "FAILED");

    // Either factory hook landing is enough to upgrade new links. Setter
    // hooks are defensive; missing them isn't fatal.
    installed = cadl_factory_ok || uis_factory_ok;
    return installed;
}
