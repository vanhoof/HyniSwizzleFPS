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

#ifdef __cplusplus
}
#endif

#endif
