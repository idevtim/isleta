#!/bin/bash
# Build, sign, notarize and publish a release, and regenerate the Sparkle appcast.
#
# ─── STATUS ─────────────────────────────────────────────────────────────────
# This script has NEVER been run end to end. Isleta has no released version yet, so the
# notarization and publication steps below are untested here. The build-and-sign half
# *has* been verified: the inside-out signing order was run against a Release build in
# this checkout because without it the app will not even launch (see "Why signing is not
# optional" below). Treat everything after `notarytool` as adapted from a working script
# for another app by the same author, not as proven — the first real run is the test.
#
# The EdDSA key pair was generated on 2026-08-19 and SUPublicEDKey holds the real public
# half, so prerequisite 1 below is history rather than a to-do.
#
# ─── Prerequisites ──────────────────────────────────────────────────────────
# 1. An EdDSA key pair. DONE 2026-08-19 — kept here because it is the only record of how,
#    and because a lost key cannot be regenerated, only replaced (which strands every
#    existing install). Generated ONCE with:
#
#        # Sparkle's tools ship in the release artifact, not in the SPM package.
#        curl -L -o /tmp/Sparkle.tar.xz \
#          https://github.com/sparkle-project/Sparkle/releases/download/2.6.0/Sparkle-2.6.0.tar.xz
#        tar -xf /tmp/Sparkle.tar.xz -C /tmp
#        /tmp/bin/generate_keys
#
#    `generate_keys` puts the PRIVATE key in the login keychain as "Private key for
#    signing Sparkle updates" and prints the PUBLIC key. Paste the printed public key
#    into `SUPublicEDKey` in Config/Isleta-Info.plist, replacing the placeholder.
#
#    THE PRIVATE KEY NEVER ENTERS THIS REPOSITORY. Not in a file, not in .env, not in CI
#    config, not in a comment. It lives in the login keychain, and `generate_keys -x` is
#    the only way to export it — do that only to put a copy in a password manager as the
#    backup, because losing it means no existing install can ever be updated again. A new
#    key pair does not rescue them: they verify against the key that shipped inside them.
#
#    Do NOT reuse another app's key. A leak of one private key must not let an attacker
#    sign updates for two applications.
#
# 2. `.env` in the repo root (gitignored), with:
#        APPLE_TEAM_ID=...
#        APPLE_ID=...
#        APPLE_APP_SPECIFIC_PASSWORD=...
#
# 3. A "Developer ID Application" certificate in the keychain, and `gh` authenticated.
#
# ─── Why signing is not optional, even locally ──────────────────────────────
# The project's Release configuration sets CODE_SIGN_IDENTITY = "-" (ad-hoc). With
# Sparkle embedded that produces an app that CANNOT LAUNCH: hardened runtime is on,
# library validation requires the app and its embedded framework to share a Team ID, and
# two independently ad-hoc-signed binaries share none. dyld refuses Sparkle.framework
# with "different Team IDs". Debug builds survive only because they carry
# `get-task-allow`, which relaxes library validation — so this failure appears the first
# time anyone builds Release and never before. That is why this script overrides
# CODE_SIGN_IDENTITY and DEVELOPMENT_TEAM rather than trusting the project settings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.env"
  set +a
else
  echo "❌ .env not found at $PROJECT_DIR/.env — see the header of this script"
  exit 1
fi

: "${APPLE_TEAM_ID:?APPLE_TEAM_ID must be set in .env}"
: "${APPLE_ID:?APPLE_ID must be set in .env}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD must be set in .env}"

APP_NAME="Isleta"
# The source, the releases and the appcast are all one public repo as of 2026-09-01, when Isleta
# was open sourced. It used to be two — a private source repo (idevtim/isleta-app) and this one for
# releases — because `raw.githubusercontent.com` on a private repo requires a token, so an appcast
# served from there would 404 for every user and Sparkle would silently never find an update. That
# split is gone; the constraint it existed for is still the reason this repo must stay public.
#
# idevtim/isleta-app still exists as the private archive of the pre-open-source history and of the
# files that are not published. `Tools/private-sync.sh` is what writes to it.
GITHUB_REPO="idevtim/isleta"
INFO_PLIST="$PROJECT_DIR/Config/Isleta-Info.plist"
ENTITLEMENTS="$PROJECT_DIR/Config/Isleta.entitlements"
# The Developer ID *provisioning profile*, which Isleta needs only because it claims an entitlement
# — WeatherKit — that has to be authorised by one. It is committed rather than kept out of the repo
# because it ships inside every copy of the app at Contents/embedded.provisionprofile and is
# therefore public by construction; it carries no private key.
PROFILE="$PROJECT_DIR/Config/Isleta.provisionprofile"
SIGNING_IDENTITY="Developer ID Application: Tim Murphy ($APPLE_TEAM_ID)"

BUILD_DIR="$PROJECT_DIR/.build/release"
DERIVED_DIR="$BUILD_DIR/DerivedData"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
# Sparkle downloads a zip. Kept in its own directory because generate_appcast treats that
# directory as the archive set it maintains.
UPDATES_DIR="$BUILD_DIR/updates"
APPCAST_PATH="$PROJECT_DIR/appcast.xml"

# ─── Pre-flight ─────────────────────────────────────────────────────────────
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INFO_PLIST")
RELEASE_NOTES="$PROJECT_DIR/release-notes/v$VERSION.md"

# Sparkle decides whether an update is newer by comparing CFBundleVersion, not the
# marketing string. If it does not increase, every existing install silently concludes it
# is already up to date — a failure with no error anywhere. Checked rather than
# auto-synced because PlistBuddy rewrites the file and strips its comments, and this
# plist's comments are load-bearing documentation.
if [ "$BUNDLE_VERSION" != "$VERSION" ]; then
  echo "❌ CFBundleVersion ($BUNDLE_VERSION) != CFBundleShortVersionString ($VERSION)"
  echo "   Sparkle compares CFBundleVersion — users would never be offered this update."
  exit 1
fi

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$INFO_PLIST")
case "$PUBLIC_KEY" in
  REPLACE-WITH-*|"")
    echo "❌ SUPublicEDKey is still the placeholder."
    echo "   Run generate_keys (see the header of this script) and paste the public key"
    echo "   into $INFO_PLIST. Until then the shipped app refuses to check for updates,"
    echo "   which is the safe failure — but a release signed against no key is useless."
    exit 1
    ;;
esac

if [ ! -f "$RELEASE_NOTES" ]; then
  echo "❌ Missing release notes: release-notes/v$VERSION.md"
  exit 1
fi
# ─── Pre-flight: entitlements and the profile that has to authorise them ────
#
# The failure this prevents is the worst-behaved one this project has met. An entitlement that no
# embedded provisioning profile authorises does not warn, does not fail to sign, and does not
# produce a crash report — `codesign` accepts it silently and the app exits **137** on launch, with
# AMFI logging "Unsatisfied Entitlements" to the kernel log and nothing anywhere else. It is the
# 1.3.0 Bluetooth abort's shape: invisible until a real launch, and invisible to every check that
# runs from a shell.
#
# So the rule is checked here, in both directions, before anything is built.
CLAIMED_ENTITLEMENTS=$(/usr/libexec/PlistBuddy -c "Print" "$ENTITLEMENTS" 2>/dev/null \
  | grep -oE "com\.apple\.developer\.[a-zA-Z0-9._-]+" | sort -u || true)

if [ -n "$CLAIMED_ENTITLEMENTS" ]; then
  if [ ! -f "$PROFILE" ]; then
    echo "❌ Config/Isleta.entitlements claims a developer entitlement and there is no"
    echo "   provisioning profile at Config/Isleta.provisionprofile to authorise it:"
    echo "$CLAIMED_ENTITLEMENTS" | sed 's/^/      /'
    echo "   Signing this would produce an app that exits 137 on every launch with no crash report."
    echo "   Create a *Developer ID* distribution profile for com.tryisleta.isleta and save it there."
    exit 1
  fi

  # A profile is CMS-signed; `security cms -D` is what turns it back into a readable plist.
  PROFILE_PLIST=$(security cms -D -i "$PROFILE" 2>/dev/null) || {
    echo "❌ Could not decode $PROFILE — is it really a .provisionprofile?"; exit 1; }

  for ent in $CLAIMED_ENTITLEMENTS; do
    if ! printf '%s' "$PROFILE_PLIST" | grep -q "$ent"; then
      echo "❌ The profile does not authorise $ent."
      echo "   On developer.apple.com the capability must be ticked on BOTH the App Services tab"
      echo "   and the App Capabilities tab — ticking one gives a profile that validates and a"
      echo "   service that refuses at runtime. Re-generate the profile after ticking both."
      exit 1
    fi
  done

  # Gatekeeper validates the profile at *every launch*, so an expired one does not degrade a
  # feature — it stops the app opening at all, for everyone who has it installed.
  PROFILE_EXPIRY=$(printf '%s' "$PROFILE_PLIST" \
    | /usr/libexec/PlistBuddy -c "Print :ExpirationDate" /dev/stdin 2>/dev/null || true)
  echo "   ✓ profile authorises:$(echo "$CLAIMED_ENTITLEMENTS" | tr '\n' ' ')"
  echo "   ✓ profile expires $PROFILE_EXPIRY — Gatekeeper checks this on every launch"

  # xcodebuild resolves PROVISIONING_PROFILE_SPECIFIER by *name*, and only from Xcode's own
  # directory — a profile sitting in Config/ is invisible to it. Without this copy the build stops
  # at GatherProvisioningInputs with "requires a provisioning profile with the WeatherKit feature",
  # which reads as a project misconfiguration rather than a missing file.
  #
  # The *name* is set in the project, on the Isleta target's Release configuration, and is
  # deliberately NOT passed on the command line any more. A setting passed to `xcodebuild` applies
  # to **every target in the build graph**, and since the packages gained localized resources
  # SwiftPM generates a resource-bundle target for each of them — `IslandUI_IslandUI` and three
  # siblings. A resource bundle cannot hold a provisioning profile, so all four fail with
  # "does not support provisioning profiles ... has been manually specified", and the whole build
  # stops. It is a confusing failure because nothing about it mentions resources or localization:
  # the first release build after that change is where it appears, and the error names a package
  # manifest that has nothing wrong with it.
  PROFILE_NAME=$(printf '%s' "$PROFILE_PLIST" \
    | /usr/libexec/PlistBuddy -c "Print :Name" /dev/stdin 2>/dev/null)
  PROFILE_UUID=$(printf '%s' "$PROFILE_PLIST" \
    | /usr/libexec/PlistBuddy -c "Print :UUID" /dev/stdin 2>/dev/null)
  XCODE_PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  mkdir -p "$XCODE_PROFILES"
  cp "$PROFILE" "$XCODE_PROFILES/$PROFILE_UUID.provisionprofile"
  echo "   ✓ profile \"$PROFILE_NAME\" installed for xcodebuild"
elif [ -f "$PROFILE" ]; then
  echo "   ℹ a provisioning profile is present but no developer entitlement is claimed;"
  echo "     it will be embedded anyway, which is harmless and keeps the two in step."
fi

echo "✓ v$VERSION — version keys agree, public key present, release notes found"

# ─── Build ──────────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$UPDATES_DIR"

echo "🔨 Building $APP_NAME (Release)..."
xcodebuild \
  -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGN_STYLE="Manual" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  2>&1 | tail -5

BUILT_APP=$(find "$DERIVED_DIR" -name "$APP_NAME.app" -type d | head -1)
if [ -z "$BUILT_APP" ]; then
  echo "❌ Build failed — .app not found"
  exit 1
fi
cp -R "$BUILT_APP" "$APP_PATH"

# ─── Deep sign, inside-out ──────────────────────────────────────────────────
echo "🔏 Signing inside-out..."

# Sparkle ships four executables nested inside its framework — two XPC services, an
# updater app and the Autoupdate tool. Signing only the .framework leaves those carrying
# Sparkle's own signature, and notarization rejects the build. They have to be signed
# individually, innermost first.
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  for nested in \
    "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_FW/Versions/B/Updater.app" \
    "$SPARKLE_FW/Versions/B/Autoupdate"; do
    if [ -e "$nested" ]; then
      codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$nested"
      echo "   ✓ Sparkle/$(basename "$nested")"
    fi
  done
fi

if [ -d "$APP_PATH/Contents/Frameworks" ]; then
  find "$APP_PATH/Contents/Frameworks" -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) |
    while read -r lib; do
      codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$lib"
      echo "   ✓ $(basename "$lib")"
    done
fi

# Copied in *before* the final signature, so the profile is sealed inside it. A profile added
# afterwards is unsealed content and `codesign --verify --strict` rejects the bundle.
if [ -f "$PROFILE" ]; then
  cp "$PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"
  echo "   ✓ embedded.provisionprofile"
fi

codesign --force --timestamp --options runtime \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "   ✓ App signed and verified"

# ─── --build-only stops here ────────────────────────────────────────────────
#
# A signed Release build and nothing else: no notarization, no tag, no GitHub release, no appcast.
#
# It exists because **Debug cannot exercise a developer entitlement**. An ad-hoc signature cannot
# carry `com.apple.developer.*`, so `Config/Isleta-Debug.entitlements` omits WeatherKit and a Debug
# build has no weather at all — which makes `Tools/check.sh` structurally unable to see a weather
# bug, and makes "build it and look" impossible for that whole feature without cutting a release.
#
# The build it leaves in `$APP_PATH` is signed with the real identity and carries the embedded
# profile, so it runs from `/Applications` and can be launched with `open -a` — which is the only
# launch that tells the truth about permissions. It is **not** notarized, so it must never be given
# to anybody: without a ticket, Gatekeeper refuses it on any Mac that received it with a quarantine
# attribute. Locally there is no quarantine, which is exactly why this is safe here and nowhere else.
if [ "${BUILD_ONLY:-0}" = "1" ] || [ "${1:-}" = "--build-only" ]; then
  echo ""
  echo "🛑 --build-only: stopping before notarization."
  echo "   Signed, unnotarized app: $APP_PATH"
  echo "   Install with:  ditto \"$APP_PATH\" /Applications/$APP_NAME.app"
  echo "   Then launch it with 'open -a' — never from a shell — or the permissions it asks for"
  echo "   are judged against the terminal rather than against Isleta."
  echo "   Do not distribute this build: it has no notarization ticket."
  exit 0
fi

# ─── Notarize, then staple ──────────────────────────────────────────────────
# Done before zipping, so the ticket is stapled onto the .app itself. Sparkle installs
# the app straight out of the zip, and an unstapled bundle has to reach Apple to
# validate — which fails for anyone updating while offline.
echo "📤 Notarizing..."
NOTARIZE_ZIP="$BUILD_DIR/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait
rm -f "$NOTARIZE_ZIP"
xcrun stapler staple "$APP_PATH"

# ─── The update archive ─────────────────────────────────────────────────────
# --sequesterRsrc is not optional. Without it, ditto writes extended attributes as
# AppleDouble "._" files inline next to each symlink in Sparkle.framework. Sparkle's own
# extraction recombines them, but every other unzip tool leaves them on disk as literal
# files, which codesign counts as unsealed content in an embedded framework — and
# Gatekeeper then refuses the app. Sequestering puts that metadata in a sibling
# __MACOSX/ directory instead, so the bundle extracts clean whatever opens it.
ZIP_PATH="$UPDATES_DIR/$APP_NAME-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
echo "📦 $ZIP_PATH"

# ─── Appcast ────────────────────────────────────────────────────────────────
# generate_appcast signs each archive with the EdDSA private key from the login keychain.
# It is the only step that touches that key, and it never prints it.
GENERATE_APPCAST=$(find "$DERIVED_DIR/SourcePackages/artifacts" -name generate_appcast -type f 2>/dev/null | head -1)
if [ -z "$GENERATE_APPCAST" ]; then
  echo "❌ generate_appcast not found — is the Sparkle package resolved?"
  exit 1
fi

# A .md sharing the archive's basename becomes that release's notes in the update dialog.
cp "$RELEASE_NOTES" "$UPDATES_DIR/$APP_NAME-$VERSION.md"
# Seed with the committed appcast so previously published entries survive; without it the
# feed is regenerated from this one archive alone and loses its history.
[ -f "$APPCAST_PATH" ] && cp "$APPCAST_PATH" "$UPDATES_DIR/appcast.xml"

# --embed-release-notes puts the notes in the feed itself. Without it Sparkle derives a
# link from SUFeedURL and expects the .md beside the appcast in the repo root, which 404s.
"$GENERATE_APPCAST" \
  --embed-release-notes \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$GITHUB_REPO" \
  --full-release-notes-url "https://github.com/$GITHUB_REPO/releases" \
  -o "$UPDATES_DIR/appcast.xml" \
  "$UPDATES_DIR"

cp "$UPDATES_DIR/appcast.xml" "$APPCAST_PATH"
echo "📰 appcast.xml updated"

# ─── Publish ────────────────────────────────────────────────────────────────
# The tag and the assets go up first. The appcast is committed *after*, because the feed
# points at a download URL that only exists once the release page does — publishing them
# the other way round offers every install an update that 404s.
# One tag, in one repo, on the commit that actually built the release. This used to be two tags of
# the same name in two repositories, because the source was private and the release was not.
git tag "v$VERSION" 2>/dev/null || echo "   tag v$VERSION already exists"
git push origin "v$VERSION"
gh release create "v$VERSION" "$ZIP_PATH" --title "v$VERSION" --notes-file "$RELEASE_NOTES" \
  --repo "$GITHUB_REPO"

echo ""
echo "✅ Released v$VERSION"
# The appcast is regenerated in place, in this repo, which is the repo `SUFeedURL` points at. It is
# left as a working-tree change rather than committed automatically: publishing an update is the one
# step that should need a person to look at it before it goes out.
echo "📋 appcast.xml regenerated at $APPCAST_PATH"
echo "   Commit and push it on $(git branch --show-current) — until that lands,"
echo "   the release exists and no installed copy is offered it."
