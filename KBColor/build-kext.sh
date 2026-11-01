#!/bin/bash
# Builds KBColor.kext.
set -euo pipefail
E="$(cd "$(dirname "$0")" && pwd)"
SDK="${MACKERNELSDK:?set MACKERNELSDK to a MacKernelSDK checkout}"
B="$E/build"; rm -rf "${B:?}/KBColor.kext" "$B"/*.o; mkdir -p "$B/KBColor.kext/Contents/MacOS"
CF=(-arch x86_64 -mkernel -fapple-kext -nostdinc -mmacosx-version-min=10.15
    -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -I"$SDK/Headers" -Os -Wall)
xcrun clang++ "${CF[@]}" -std=gnu++17 -fno-rtti -fno-exceptions -c "$E/kext/KBColor.cpp" -o "$B/KBColor.o"
xcrun clang "${CF[@]}" -c "$E/kext/kmod_info.c" -o "$B/kmod_info.o"
xcrun clang++ -arch x86_64 -mmacosx-version-min=10.15 -nostdlib -Xlinker -kext -Xlinker -export_dynamic \
    "$B/KBColor.o" "$B/kmod_info.o" "$SDK/Library/x86_64/libkmod.a" -o "$B/KBColor.kext/Contents/MacOS/KBColor"
cp "$E/kext/Info.plist" "$B/KBColor.kext/Contents/Info.plist"
echo "built: $B/KBColor.kext"
