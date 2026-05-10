// HyniSwizzleFPS — CADisplayLink swizzle to lift the iPad 60 FPS cap.

#ifndef HSFPS_H
#define HSFPS_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Install ObjC runtime swizzles on +[CADisplayLink displayLinkWithTarget:selector:]
// and -[CADisplayLink setPreferredFramesPerSecond:]. Returns true if both
// hooks were installed (factory + setter); false if either selector was
// missing from the runtime. Idempotent — safe to call more than once.
bool HSFPS_Init(void);

// The cap the engine will actually render at, accounting for device max,
// no-op cases, and the iPhone CADisableMinimumFrameDurationOnPhone clamp.
// Exposed so other injected dylibs (e.g. HynisLoader's boot banner) can
// dlsym this and report status to the user without re-implementing the
// device-class logic. Returns the device's max FPS when the upgrade will
// take effect, otherwise 60. May call into UIKit, so safe to call on the
// main thread once the UI is up; before then returns 60 conservatively.
int HSFPS_EffectiveCap(void);

#ifdef __cplusplus
}
#endif

#endif
