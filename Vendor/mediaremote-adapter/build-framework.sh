#!/bin/bash
# Rebuilds MediaRemoteAdapter.framework from the vendored sources.
#
# Upstream builds this with CMake. We do it with clang directly, because the CMake file does
# exactly three things — compile the .m files into a shared library, wrap it in a framework
# bundle, ad-hoc sign it — and requiring every developer (and CI) to install CMake to get 150KB
# of Objective-C is a dependency in everything but name.
#
# The framework is **bundled, not linked against**. Nothing in Isleta imports it; it is passed to
# the Perl script as an argument, and the script dlopens it. That is why -fvisibility=default is
# not optional: the script resolves exported functions by name, and the default hidden visibility
# CMake would otherwise apply makes the framework load and then answer nothing.
#
# arm64 only, matching the app target. Upstream ships x86_64 too; an Intel slice would be dead
# weight in a bundle that cannot run on Intel.
set -euo pipefail
cd "$(dirname "$0")"

FW="MediaRemoteAdapter.framework"
rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources" "$FW/Versions/A/Headers"

clang -dynamiclib -arch arm64 -fobjc-arc -fvisibility=default \
    -I include -I src \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name "@rpath/$FW/Versions/A/MediaRemoteAdapter" \
    -compatibility_version 1 -current_version 0.1.0 \
    -o "$FW/Versions/A/MediaRemoteAdapter" \
    src/adapter/*.m src/private/MediaRemote.m src/utility/*.m

cp include/MediaRemoteAdapter.h "$FW/Versions/A/Headers/"
cp Info.plist "$FW/Versions/A/Resources/Info.plist"

(cd "$FW/Versions" && ln -sfn A Current)
(cd "$FW" && ln -sfn Versions/Current/MediaRemoteAdapter MediaRemoteAdapter \
          && ln -sfn Versions/Current/Resources Resources \
          && ln -sfn Versions/Current/Headers Headers)

codesign --force --sign - "$FW"
echo "built $FW"
