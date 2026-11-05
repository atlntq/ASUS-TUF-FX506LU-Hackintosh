#!/bin/bash
# Builds KBColor.app (menu bar app).
set -euo pipefail
E="$(cd "$(dirname "$0")" && pwd)"
A="$E/build/KBColor.app"; rm -rf "${A:?}"; mkdir -p "$A/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 "$E/app/main.swift" -o "$A/Contents/MacOS/KBColor"
cp "$E/app/Info.plist" "$A/Contents/Info.plist"
# Loaded into apps opened with "NVIDIA ile aç" (see app/nvdefault.m).
mkdir -p "$A/Contents/Frameworks"
xcrun clang -O2 -fobjc-arc -dynamiclib -arch x86_64 -mmacosx-version-min=13.0 -framework Metal -framework Foundation \
  "$E/app/nvdefault.m" -o "$A/Contents/Frameworks/libnvdefault.dylib"
codesign --force --sign - "$A/Contents/Frameworks/libnvdefault.dylib"
codesign --force --sign - "$A"
echo "built: $A"
