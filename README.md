# HyniSwizzleFPS

Lifts Minecraft: Bedrock Edition's 60 FPS cap on ProMotion iPads and iPhones for sideloaded (non-jailbroken) installs.

Designed to be injected alongside [HyniSign](https://github.com/vanhoof/HyniSign) (Microsoft sign-in fix) and [HynisLoader](https://github.com/congcq/HynisLoader)'s `MaterialLoader.dylib` (RenderDragon shader loader). Each is a separate dylib injection — no shared state.

## The problem

On a sideloaded Minecraft IPA running on a ProMotion device, the in-game **Performance HUD** shows a flat 60 FPS even though the iPad Pro M-series and iPhone Pro 13+ have 120 Hz displays. The in-game FPS slider tops out at 60 with no frame-pacing toggle (unlike the Android build), and Game Mode toggling makes no difference.

The cause isn't the engine. It's iOS:

- `+[CADisplayLink displayLinkWithTarget:selector:]` and `-[UIScreen displayLinkWithTarget:selector:]` return a **60 Hz link by default** on ProMotion devices, regardless of the device's actual refresh rate.
- Apps must explicitly opt into higher rates by setting `preferredFrameRateRange` (iOS 15+) or `preferredFramesPerSecond` (iOS 10+) on the link they create.
- Mojang's iOS target doesn't opt in. MCBE 1.26.13 still uses the legacy `setFrameInterval:` setter, which has been a no-op against the ProMotion cap since iOS 10.

The render loop runs once per display-link callback with no separate engine throttle, so the display link being capped at 60 Hz means the entire game runs at 60 Hz with GPU headroom to spare.

## What this fix does

A small dylib that swizzles four iOS render-loop entry points using ObjC runtime APIs. Each time MCBE creates a `CADisplayLink`, the swizzle runs after the original factory and writes `preferredFrameRateRange = (60, 120, 120)` to the link. Apple's docs are explicit that `preferredFrameRateRange` takes precedence over both `preferredFramesPerSecond` and the legacy `frameInterval` when set, so this wins regardless of what MCBE does next.

The four hooks:

| Hook | Why |
|---|---|
| `-[UIScreen displayLinkWithTarget:selector:]` | The factory MCBE 1.26.13 actually uses. Confirmed via Console.app — target object is `minecraftpeViewControllerImpl`. |
| `+[CADisplayLink displayLinkWithTarget:selector:]` | The other documented factory. Defensive: future MCBE versions or other libs in-process might use it. |
| `-[CADisplayLink setFrameInterval:]` | MCBE calls this with `1` right after creating the link. Re-applies our range as defense in depth. |
| `-[CADisplayLink setPreferredFramesPerSecond:]` | Defensive only. Clamps upward if anything tries to downgrade the link to a sub-`max` rate. |

All hooks are gated on `UIScreen.mainScreen.maximumFramesPerSecond > 60`, so on a 60 Hz device (standard iPad, iPad mini pre-A17, iPad Air pre-M2, iPhone non-Pro) the entire path no-ops and shipping the dylib is harmless.

## Compatibility

| | |
|---|---|
| **Tested on** | iPadOS 17+, iPad Pro ProMotion (60 → 120 FPS confirmed in Performance HUD) |
| **Game versions** | Minecraft: Bedrock Edition 1.26.13 and 1.26.20 |
| **Sideloader** | Sideloadly (free Apple ID) |
| **Architecture** | arm64 |
| **Min iOS** | 14.0 (range-based API gated on `@available(iOS 15.0, *)`, falls back to `preferredFramesPerSecond` on 14) |

Should work on any iOS / iPadOS in roughly the same generation. Earlier iOS versions where TrollStore is still viable can use the same dylib — TrollStore preserves entitlements but the FPS cap is purely a display-link configuration issue, not an entitlement issue, so the same fix applies.

## Device support: iPhone needs an extra Info.plist key

The dylib alone is sufficient on **iPad ProMotion**.

On **iPhone ProMotion** (13 Pro and later, including 16 Pro Max), iOS enforces a system-level 60 Hz clamp on every display link in the process unless the app bundle's `Info.plist` contains:

```xml
<key>CADisableMinimumFrameDurationOnPhone</key>
<true/>
```

This key is read once at app launch — before any dylib runtime code runs — so the swizzle cannot set it from inside the process. Without the key, the swizzle's API call to set `preferredFrameRateRange.maximum = 120` succeeds (you'll still see `[HyniSwizzleFPS] first display link upgraded ... cap=120` in Console), but iOS silently clamps the actual frame pacing back to 60.

To support iPhone, have **Sideloadly inject the key into the IPA's `Info.plist` at sign time**. In Sideloadly's "Modify Info.plist" / "Apply Custom Args" field, add:

```
CADisableMinimumFrameDurationOnPhone:=true
```

(The `:=` form tells Sideloadly to insert the key as a Boolean `true`, not the string `"true"`.) No separate IPA repack step is needed — Sideloadly applies this when it re-signs alongside the dylib injection.

If you're patching outside Sideloadly, the equivalent on a manually unzipped IPA is:

```sh
plutil -insert CADisableMinimumFrameDurationOnPhone -bool YES \
  Payload/minecraftpe.app/Info.plist
```

Setting the key on an iPad-only install is harmless — iOS ignores it on iPad. The same patched IPA works on both device families.

| Device | Dylib alone? | Info.plist key needed? |
|---|---|---|
| iPad ProMotion (Pro M-series) | Sufficient | No (iOS ignores the key on iPad) |
| iPhone ProMotion (13 Pro+) | **Insufficient** — HUD stays at 60 | **Required** |
| Non-ProMotion iPad/iPhone | No-ops cleanly (`maximumFramesPerSecond` returns 60) | Not relevant |

## Optional: `LSSupportsGameMode` for iOS 18+ Game Mode

Unrelated to the FPS lift, but adjacent because it's another `Info.plist` key you can inject through the same Sideloadly path. iOS 18 introduced **Game Mode** (Settings → Game Mode), which boosts CPU/GPU priority for the foreground app and lowers AirPods / game-controller polling latency. Third-party apps opt in via:

```xml
<key>LSSupportsGameMode</key>
<true/>
```

The App Store Minecraft Bedrock appears to get Game Mode without this key in its `Info.plist` — Apple most likely classifies it as a game via App Store category metadata, an independent identification path that doesn't carry over to a re-signed sideload. If you want sideloaded MCBE to behave like the App Store build for Game Mode purposes, set the key explicitly.

Sideloadly "Modify Info.plist" / "Apply Custom Args":

```
LSSupportsGameMode:=true
```

Or via `plutil`:

```sh
plutil -insert LSSupportsGameMode -bool YES \
  Payload/minecraftpe.app/Info.plist
```

Game Mode is **fully orthogonal to display-link refresh rate** — the FPS dylib works the same with or without it. Treat this key as cosmetic feature-parity with the App Store build, not as part of the 60 → 120 FPS fix.

## What this does NOT do

- **Does not manage thermals for you.** Doubling the frame rate doubles GPU load. Watch the Metal HUD on iPhone — see "Thermal monitoring" below. Use at your own risk.
- **Does not bypass any anti-cheat or attestation.** Cosmetic frame-rate lift; same surface area as setting `preferredFrameRateRange` in any normal iOS app.
- **Does not raise the in-game FPS slider's UI ceiling.** The slider stays at 60. The engine renders at 120 regardless — the slider is UI-only and doesn't reflect the actual frame pacing. If you want the slider itself to show 120, that requires a separate vtable hook on the Options screen's max-value getter.
- **Does not allocate executable memory.** ObjC swizzling is pure runtime metadata manipulation — no RWX pages, no JIT entitlement, no CydiaSubstrate.
- **Does not sign or install the IPA.** That's Sideloadly's job.
- **Does not provide the patched Minecraft IPA.** This repo only adds the FPS lift; you supply the IPA.

## Build

Requires:

- macOS with Xcode Command Line Tools
- [Theos](https://theos.dev/) installed and `$THEOS` in your shell

```sh
git clone https://github.com/vanhoof/HyniSwizzleFPS
cd HyniSwizzleFPS
make
```

Output: `build/HyniSwizzleFPS.dylib`. The dylib uses an `@executable_path` install name and is ad-hoc signed; Sideloadly will re-sign it with your cert when injecting.

If you'd rather not build it yourself, prebuilt `HyniSwizzleFPS.dylib` artifacts are attached to each [GitHub Release](../../releases). Tagged commits (`v*`) automatically build, test, and publish via CI.

## Tests

**Build smoke tests** for the produced iOS dylib — verify architecture (arm64-only), `@executable_path` install name, framework dependencies (Foundation, UIKit, QuartzCore), absence of CydiaSubstrate, and presence of the `CADisplayLink` classref + the swizzle target selectors:

```sh
make                        # build the dylib first
bash tests/check-build.sh   # then verify it
```

There are no host unit tests. The hook logic is small enough (~30 LoC of branching) that synthetic test scaffolding would outweigh the code under test; runtime behavior is observable directly via Console.app and the in-game Performance HUD.

## Install

1. Open **Sideloadly** on your Mac (or Windows).
2. Plug in your iPad / iPhone, trust the computer.
3. Drag your Minecraft IPA onto the Sideloadly window. Click the **gear icon → Advanced options**.
4. Under **Inject dylibs/deb/bundle**, add `build/HyniSwizzleFPS.dylib`. (You can add other dylibs in the same step — `MaterialLoader.dylib` from HynisLoader, `HyniSign.dylib`, `MCClient.dylib`.)
5. **iPhone ProMotion only** — under **Modify Info.plist** (or "Apply Custom Args"), add:

   ```
   CADisableMinimumFrameDurationOnPhone:=true
   ```

   This step is harmless on iPad and required on iPhone. See "Device support" above.

6. Enter your Apple ID and start. Trust the developer cert in *Settings → General → VPN & Device Management* on the device.

## Verify it's working

1. Plug iPad / iPhone into your Mac, open **Console.app**, select the device, filter `process:minecraftpe`, start streaming.
2. Launch Minecraft. You should see, near the top:

   ```
   [HyniSwizzleFPS] loading
   [HyniSwizzleFPS] hooks installed: cadl_factory=ok uis_factory=ok fps_setter=ok interval_setter=ok
   [HyniSwizzleFPS] init: ok
   ```

3. About a second after launch, when the render loop spins up, you should see:

   ```
   [HyniSwizzleFPS] first display link upgraded via -UIScreen: target=minecraftpeViewControllerImpl sel=<private> cap=120
   [HyniSwizzleFPS] setFrameInterval(1) intercepted; range re-applied
   ```

4. **In game** — open Settings → Video → enable the Performance HUD. It should show ~120 FPS instead of a flat 60 (capped by your scene's GPU load, of course). The in-game FPS slider will still cap at 60; that's the UI ceiling, not the engine.

## Thermal monitoring (especially on iPhone)

Running at 120 FPS roughly doubles GPU work, which means more heat. iPad Pro chassis handle it fine. **iPhone runs hotter** — smaller chassis, worse if you're charging, in a case, or in the sun.

Keep an eye on thermals, especially during your first few sessions:

- **Metal HUD** — Settings → Developer → Metal HUD, enable for Minecraft. Watch the thermal-state line (`Nominal` / `Fair` / `Serious` / `Critical`). If it sits at `Serious` or `Critical`, drop back to 60 FPS until the device cools.
- **Touch test** — if the back is uncomfortable to hold, you're already past `Fair`. Stop and let it cool.

**Use at your own risk.** This dylib is provided as-is. The author isn't responsible for any damage to your device, battery, accounts, or data that results from using it. If that's not a tradeoff you're comfortable with, don't install it.

## Troubleshooting

- **No `[HyniSwizzleFPS]` lines in Console at all.** The dylib didn't load — Sideloadly's "Inject dylibs" step didn't take, or the load command isn't pointing at the right path. Re-check the inject list and re-sign.

- **You see `first display link upgraded ... cap=120` but the HUD still shows a flat 60.**
  - **iPhone:** confirm the IPA's `Info.plist` has `CADisableMinimumFrameDurationOnPhone = YES`. Without it, iOS clamps the link at the system level — the API call succeeds (we log `cap=120`), but the actual rate stays at 60. See "Device support" above.
  - **iPad:** the engine likely gained an internal throttle reading something like `gfx_max_framerate`. The next move is a vtable hook on the Options getter, but no MCBE version we've tested actually has this; report a bug if you hit it.

- **No `first display link upgraded` line ever fires.** MCBE shifted to a different factory — for example, the `[[CADisplayLink alloc] initWithBlock:]` ProMotion-aware initializer added in iOS 17, or a `CAMetalDisplayLink` (also iOS 17+) for Metal-backed rendering. Identify the new factory in `otool -ov` output and add a parallel swizzle.

- **MCBE crashes on launch with the dylib injected.** Almost certainly an architecture or signing mismatch — the dylib must be `arm64`-only, ad-hoc signed, with `@executable_path/HyniSwizzleFPS.dylib` as its install name. Run `bash tests/check-build.sh` against the dylib that ended up in the IPA to verify.

## How it works

We can't use `MSHookFunction` (CydiaSubstrate-style inline patching) on modern non-jailbroken iOS — system framework code pages are write-protected and pointer-authentication-signed (PAC), and CydiaSubstrate isn't present anyway. We also don't use Logos `%hook`, which would emit a `dlopen` of `/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate` and fail to load the dylib at runtime.

Instead, we use **ObjC method swizzling** via the runtime APIs (`class_getClassMethod` + `method_setImplementation`) — pure Foundation/QuartzCore runtime work, no RWX page allocation, no JIT entitlement. This works because Apple's `CADisplayLink` and `UIScreen` are normal ObjC classes whose method tables we can rewrite from inside the process.

The factory hooks (`+[CADisplayLink displayLinkWithTarget:selector:]` and `-[UIScreen displayLinkWithTarget:selector:]`) are the load-bearing ones — they catch every link MCBE creates and apply our `preferredFrameRateRange` to the freshly-minted instance before returning. The setter hooks (`setFrameInterval:`, `setPreferredFramesPerSecond:`) are defensive: if a future MCBE refactor explicitly downgrades the link's rate after creation, we re-apply the range or clamp upward.

Apple's docs are explicit that `preferredFrameRateRange` takes precedence over `preferredFramesPerSecond` and the legacy `frameInterval` when both are set. So writing `(60, 120, 120)` once at link creation wins regardless of what MCBE does to it after.

This dylib is **independent of MCBE updates** in a way that vtable hooks aren't. As long as iOS keeps `+[CADisplayLink displayLinkWithTarget:selector:]` and the modern frame-rate API around, the swizzle keeps working — Mojang stripping RTTI or rearranging C++ classes doesn't affect it.

## Acknowledgments

- [HynisLoader](https://github.com/congcq/HynisLoader) by congcq — the upstream MaterialLoader / RenderDragon shader-loading dylib this is meant to coexist with.
- [HyniSign](https://github.com/vanhoof/HyniSign) — Microsoft / Xbox sign-in fix for the same ecosystem; this project's structure and CI are patterned on it.
- Apple's `CADisplayLink` documentation and the iOS 15 `CAFrameRateRange` API, without which there'd be nothing to call.

## License

MIT.
