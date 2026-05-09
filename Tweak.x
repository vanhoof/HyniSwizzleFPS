// HyniSwizzleFPS — sideload-injected dylib that lifts Minecraft Bedrock's
// 60 FPS cap on ProMotion iPads (and iPhones, with the matching Info.plist
// patch) by swizzling CADisplayLink to run at the device's max refresh rate.
//
// %ctor here is just an entry point — the actual swizzle lives in
// src/fps.m. Logos %hook would pull in CydiaSubstrate (absent on
// non-jailbroken iOS), so we use ObjC runtime APIs directly instead.

#import <Foundation/Foundation.h>

#include "fps.h"

#define LOG(fmt, ...) NSLog(@"[HyniSwizzleFPS] " fmt, ##__VA_ARGS__)

%ctor {
    LOG(@"loading");
    bool ok = HSFPS_Init();
    LOG(@"init: %s", ok ? "ok" : "FAILED");
}
