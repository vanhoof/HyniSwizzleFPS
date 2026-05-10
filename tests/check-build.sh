#!/bin/bash
# check-build.sh — smoke tests for the built HyniSwizzleFPS.dylib.
#
# Verifies architecture, install name, framework dependencies, absence of
# CydiaSubstrate, and that the CADisplayLink classref survived link-time
# DCE (proves the swizzle target is referenced).
#
#   bash tests/check-build.sh

set -e

DYLIB="${1:-build/HyniSwizzleFPS.dylib}"

if [ ! -f "$DYLIB" ]; then
    echo "ERROR: $DYLIB not found. Run 'make' from the project root first." >&2
    exit 1
fi

failed=0
check() {
    local name="$1"
    local cond="$2"
    if [ "$cond" = "ok" ]; then
        printf "  ok    %s\n" "$name"
    else
        printf "  FAIL  %s — %s\n" "$name" "$cond"
        failed=$((failed + 1))
    fi
}

echo "Checking $DYLIB..."

# Architecture: arm64 only (matches the target Minecraft binary).
archs=$(lipo -archs "$DYLIB" 2>/dev/null || echo "?")
if [ "$archs" = "arm64" ]; then
    check "arm64-only architecture" ok
else
    check "arm64-only architecture" "got '$archs'"
fi

# Install name must point at @executable_path so it loads alongside the
# Minecraft binary regardless of where the IPA gets installed.
iname=$(otool -D "$DYLIB" | tail -n +2 | tr -d '[:space:]')
expected_iname="@executable_path/HyniSwizzleFPS.dylib"
if [ "$iname" = "$expected_iname" ]; then
    check "install_name=$expected_iname" ok
else
    check "install_name=$expected_iname" "got '$iname'"
fi

# Required framework dependencies. CADisplayLink lives in QuartzCore;
# UIScreen.maximumFramesPerSecond lives in UIKit.
linkage=$(otool -L "$DYLIB")
for fw in Foundation UIKit QuartzCore; do
    if echo "$linkage" | grep -q "/${fw}.framework/${fw}"; then
        check "links ${fw}.framework" ok
    else
        check "links ${fw}.framework" "missing"
    fi
done

# Must NOT depend on CydiaSubstrate. ObjC swizzling uses the runtime
# directly; trampoline-style hooks would need RWX/JIT which sideload
# certs don't grant.
if echo "$linkage" | grep -q "CydiaSubstrate"; then
    check "no CydiaSubstrate dependency" "found CydiaSubstrate in load commands"
else
    check "no CydiaSubstrate dependency" ok
fi

# Class we swizzle is referenced through the ObjC classref symbol
# rather than a literal string. If DCE somehow ate the hook, this
# undefined import disappears from the dynamic symbol table.
classrefs=$(nm -u "$DYLIB" 2>/dev/null || true)
if echo "$classrefs" | grep -q "_OBJC_CLASS_\$_CADisplayLink"; then
    check "imports _OBJC_CLASS_\$_CADisplayLink" ok
else
    check "imports _OBJC_CLASS_\$_CADisplayLink" "symbol not found"
fi

# Selector strings the hooks bind to.
strings_out=$(strings "$DYLIB")
for sel in displayLinkWithTarget:selector: setPreferredFramesPerSecond: maximumFramesPerSecond; do
    if echo "$strings_out" | grep -qx "$sel"; then
        check "embeds selector '${sel}'" ok
    else
        check "embeds selector '${sel}'" "string not found"
    fi
done

# Public function present in the symbol table.
syms=$(nm "$DYLIB" 2>/dev/null || true)
for sym in HSFPS_Init HSFPS_EffectiveCap; do
    if echo "$syms" | grep -q " _${sym}\$"; then
        check "defines ${sym}" ok
    else
        check "defines ${sym}" "symbol not found"
    fi
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All build smoke tests passed."
    exit 0
else
    echo "$failed check(s) failed." >&2
    exit 1
fi
