#!/bin/bash
#
# Sign the **Debug** build with the Developer ID identity, so TCC grants survive a rebuild.
#
# ## Why this exists
#
# A Debug build is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"` — see `Config/Isleta-Debug.entitlements`
# for why that file exists at all), and an ad-hoc signature's cdhash changes on every build. TCC keys
# a grant to the signature, so every rebuild silently drops it: Accessibility is granted, the next
# `xcodebuild` runs, and the app is untrusted again with nothing on screen to say so. That makes any
# permission-dependent feature untestable in Debug — which is where `--hud-demo`, `--media-key-test`
# and `--request-accessibility` live.
#
# Signing the Debug bundle with the real Developer ID identity fixes it: the identity is stable, so
# one grant holds across every rebuild. Run this after `Tools/check.sh` or a bare `xcodebuild`.
#
# **This is not `Tools/release.sh`.** Nothing here is notarized, nothing is stapled, and the Debug
# entitlements are used rather than the Release ones. It exists to make a *development* build
# testable, and its output must never be shipped.
#
# ## The two traps
#
# **Sign inside-out, and Sparkle's nested code individually.** Sparkle carries its own signatures on
# an XPC service, an updater app and a helper; re-signing the framework wholesale invalidates them
# and `codesign --verify --deep --strict` rejects the bundle. Same order `Tools/release.sh` uses.
#
# **`Contents/MacOS/*.dylib` is not optional, and it is Debug-only.** Xcode's debug-dylib build mode
# puts `Isleta.debug.dylib` (and `__preview.dylib`) beside the executable. Leave them ad-hoc while
# the app is Developer ID signed and the app does not launch at all: dyld refuses with "mapping
# process and mapped file (non-platform) have different Team IDs", the process aborts before `main`,
# and the crash report says `Library not loaded` rather than anything about signing. Measured
# 2026-08-29 — the first attempt at this script omitted them and cost a launch loop to find.
#
# No `embedded.provisionprofile` is copied in, deliberately: `Config/Isleta-Debug.entitlements`
# carries no `com.apple.developer.*` key, so nothing needs profile authorisation and the exit-137
# abort CLAUDE.md warns about cannot arise here.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$PROJECT_DIR/.build/xcode/Build/Products/Debug/Isleta.app}"
TEAM_ID="${APPLE_TEAM_ID:-UA2RJP3TSL}"
# Select a certificate by exact name or SHA-1 with CODE_SIGN_IDENTITY, or store that one line in
# .build/debug-signing-identity for this checkout. APPLE_TEAM_ID customizes the Developer ID default.
LOCAL_IDENTITY_FILE="$PROJECT_DIR/.build/debug-signing-identity"
if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODE_SIGN_IDENTITY"
elif [ -s "$LOCAL_IDENTITY_FILE" ]; then
  IFS= read -r IDENTITY < "$LOCAL_IDENTITY_FILE"
else
  IDENTITY="Developer ID Application: Tim Murphy ($TEAM_ID)"
fi
ENTITLEMENTS="$PROJECT_DIR/Config/Isleta-Debug.entitlements"

[ -d "$APP" ] || { echo "❌ no app at $APP — build it first"; exit 1; }
security find-identity -v -p codesigning | grep -Fq -- "$IDENTITY" \
  || { echo "❌ the requested codesigning identity is unavailable: $IDENTITY"; exit 1; }

echo "==> signing $(basename "$APP") as $IDENTITY"

sign() { codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$@" 2>&1 | sed 's/^/   /'; }

# Sparkle's nested code, innermost first.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for nested in \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate"; do
    [ -e "$nested" ] && sign "$nested"
  done
fi

# Then every framework and dylib beside them.
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) |
    while read -r lib; do sign "$lib"; done
fi

# Then the debug dylibs next to the executable. See the note above — this is the one that aborts
# the launch if it is skipped.
find "$APP/Contents/MacOS" -maxdepth 1 -name "*.dylib" | while read -r lib; do sign "$lib"; done

# The app last, so everything above is sealed inside its signature.
sign --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/   /'
echo "==> identity"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier)=" | sed 's/^/   /'
echo "✓ signed. TCC grants for this app now survive a rebuild, as long as this script is re-run after each one."
