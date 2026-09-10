#!/bin/bash
# Build and test everything the way CI should.
#
# Warnings-as-errors lives here for the packages rather than in their manifests: Xcode compiles
# package dependencies with `-suppress-warnings`, which conflicts with `-warnings-as-errors` set in
# a manifest and fails the app build outright. The app target keeps
# SWIFT_TREAT_WARNINGS_AS_ERRORS = YES in the project (§3); this script gives the packages the same
# treatment under SwiftPM, where Xcode is not in the way.
#
# All packages share one scratch path. Without it each package keeps its own build directory with
# its own cached copy of IslandKit, and SwiftPM does not invalidate that copy when a *new* source
# file is added to a path dependency — so adding a file to IslandKit makes every dependent package
# fail with "cannot find type", once each, until it is built a second time.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH="$PWD/.build/spm"

for package in Packages/*/; do
    name=$(basename "$package")
    echo "==> $name"
    swift build --package-path "$package" --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
    if [ -d "$package/Tests" ]; then
        swift test --package-path "$package" --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
    fi
done

# The app shell has no test target, so its localization tables are checked here rather than by a
# `LocalizationCoverageTests` of their own — and the same script re-checks the four packages against
# `Config/Isleta-Info.plist`, which is the one authority their own tests cannot see. A language in
# a package and missing from `CFBundleLocalizations` never resolves at runtime; a language in the
# plist and missing from a package draws English with nothing to say so.
echo "==> localization"
python3 Tools/localization-audit.py

# **The status is taken from `xcodebuild` and not from the pipeline**, and that is the whole of this
# block. `xcodebuild … | grep …` under `pipefail` reports whichever end failed, and the `|| true`
# that stops a *no matches* grep from killing the run swallowed the build's own exit code with it —
# so a failing app build printed "** BUILD FAILED **", the script carried on to the localization
# audit, and `check.sh` exited 0. Every package above is checked by `set -e`; this one step, the one
# that builds the thing that actually ships, was not.
#
# `tee` keeps the filtered output arriving live and puts the whole log somewhere readable, because
# the grep drops the lines that say *which* file failed — and `${PIPESTATUS[0]}` is read in the
# `||` branch, before anything else can reset it.
echo "==> Isleta.app"
APP_BUILD_LOG="$PWD/.build/xcode-build.log"
mkdir -p "$(dirname "$APP_BUILD_LOG")"
app_build_status=0
xcodebuild -project Isleta.xcodeproj -scheme Isleta -configuration Debug \
    -derivedDataPath .build/xcode build 2>&1 \
    | tee "$APP_BUILD_LOG" \
    | grep -E "error:|warning:|BUILD" || app_build_status=${PIPESTATUS[0]}
if [ "$app_build_status" -ne 0 ]; then
    echo "Isleta.app failed to build (xcodebuild exit $app_build_status)."
    echo "The full log is at $APP_BUILD_LOG — the lines above are only what matched the filter."
    exit "$app_build_status"
fi

# The other half of the localization audit, and it can only run once the app exists: neither
# xcodebuild nor SwiftPM prunes a deleted `.lproj`, so an incremental build can carry a language the
# source tree has retired — and `Bundle.localizations` unions the on-disk set with
# `CFBundleLocalizations`, so that language is still offered to a user set to it.
echo "==> localization (built app)"
python3 Tools/localization-audit.py --built-app .build/xcode/Build/Products/Debug/Isleta.app
