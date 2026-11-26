#!/bin/bash
set -euo pipefail

SDK="${SDK:-/tmp/sdk2/iPhoneOS16.5.sdk}"
SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$SRC/_build}"
CC=/usr/bin/clang
LIPO=/usr/bin/llvm-lipo-18

BASE_FLAGS=(-isysroot "$SDK" -fobjc-arc -fblocks -O2
            -Wall -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations
            -Wno-nullability-completeness -Wno-objc-designated-initializers -Wno-unused-parameter
            -fobjc-weak)

rm -rf "$OUT"
mkdir -p "$OUT/obj"

compile () {
  local src="$1" obj="$2" triple="$3"
  "$CC" -target "$triple" "${BASE_FLAGS[@]}" -c "$src" -o "$obj"
}

link_dylib () {
  local triple="$1" out="$2"; shift 2
  "$CC" -target "$triple" -isysroot "$SDK" -fuse-ld=lld -Wl,-undefined,dynamic_lookup \
        -dynamiclib -o "$out" "$@" \
        -framework UIKit -framework Foundation -framework AudioToolbox -framework IOKit \
        -Wl,-install_name,/var/jb/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib
}

link_bundle () {
  local triple="$1" out="$2"; shift 2
  "$CC" -target "$triple" -isysroot "$SDK" -fuse-ld=lld -Wl,-undefined,dynamic_lookup \
        -bundle -o "$out" "$@" \
        -framework UIKit -framework Foundation
}

for arch in arm64; do
  triple="${arch}-apple-ios16.0"
  echo "==> compiling tweak ($arch)"
  compile "$SRC/Tweak.m"   "$OUT/obj/Tweak-$arch.o"   "$triple"
  compile "$SRC/PGPrefs.m" "$OUT/obj/PGPrefs-$arch.o" "$triple"
  link_dylib "$triple" "$OUT/GrabberCard-$arch.dylib" "$OUT/obj/Tweak-$arch.o" "$OUT/obj/PGPrefs-$arch.o"

  echo "==> compiling settings ($arch)"
  compile "$SRC/Settings/Settings.m" "$OUT/obj/Settings-$arch.o" "$triple"
  compile "$SRC/PGPrefs.m"           "$OUT/obj/Prefs-$arch.o"    "$triple"
  link_bundle "$triple" "$OUT/GrabberCardSettings-$arch" "$OUT/obj/Settings-$arch.o" "$OUT/obj/Prefs-$arch.o"
done

echo "==> collect"
cp "$OUT/GrabberCard-arm64.dylib" "$OUT/GrabberCard.dylib"
cp "$OUT/GrabberCardSettings-arm64" "$OUT/GrabberCardSettings"

echo "==> sign"
ldid -S "$OUT/GrabberCard.dylib"
ldid -S "$OUT/GrabberCardSettings"

echo "==> package"
STAGE="$OUT/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$STAGE/Library/PreferenceBundles/GrabberCardSettings.bundle"
mkdir -p "$STAGE/Library/PreferenceLoader/Preferences"
mkdir -p "$STAGE/DEBIAN"

cp "$OUT/GrabberCard.dylib" "$STAGE/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib"
cp "$SRC/GrabberCard.plist"  "$STAGE/Library/MobileSubstrate/DynamicLibraries/GrabberCard.plist"
cp "$OUT/GrabberCardSettings" "$STAGE/Library/PreferenceBundles/GrabberCardSettings.bundle/GrabberCardSettings"
cp "$SRC/Settings/Info.plist" "$STAGE/Library/PreferenceBundles/GrabberCardSettings.bundle/Info.plist"
cp "$SRC/layout/Library/PreferenceLoader/Preferences/com.grabbercard.plist" "$STAGE/Library/PreferenceLoader/Preferences/com.grabbercard.plist"
if [ -f "$SRC/Settings/GrabberCard.png" ]; then
  cp "$SRC/Settings/GrabberCard.png" "$STAGE/Library/PreferenceBundles/GrabberCardSettings.bundle/GrabberCard.png"
fi
cp "$SRC/control" "$STAGE/DEBIAN/control"

chmod 755 "$STAGE/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib"
chmod 755 "$STAGE/Library/PreferenceBundles/GrabberCardSettings.bundle/GrabberCardSettings"
chmod 644 "$STAGE/Library/MobileSubstrate/DynamicLibraries/GrabberCard.plist" \
          "$STAGE/Library/PreferenceBundles/GrabberCardSettings.bundle/Info.plist" \
          "$STAGE/Library/PreferenceLoader/Preferences/com.grabbercard.plist"

mkdir -p "$SRC/../dist"
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$SRC/../dist/GrabberCard_1.0.3_iphoneos-arm64.deb"
echo "==> DONE"
