#!/bin/bash
# Builds KBColor.app (menu bar app).
set -euo pipefail
E="$(cd "$(dirname "$0")" && pwd)"
A="$E/build/KBColor.app"; rm -rf "${A:?}"; mkdir -p "$A/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 "$E/app/main.swift" -o "$A/Contents/MacOS/KBColor"
cp "$E/app/Info.plist" "$A/Contents/Info.plist"
codesign --force --sign - "$A"
echo "built: $A"
