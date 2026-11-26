#!/bin/bash
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
SDK="${SDK:-$HOME/theos/sdks/iPhoneOS16.5.sdk}"
OUT="$ROOT/build"
PKG="$ROOT/packages"
DIST="$ROOT/dist"
CC="${CC:-$(xcrun --sdk iphoneos --find clang)}"
LIPO="$(xcrun --find lipo)"
LDID="${LDID:-$HOME/theos/bin/ldid}"

rm -rf "$OUT" "$PKG" "$DIST"
mkdir -p "$OUT/obj" "$PKG" "$DIST"

BASE_FLAGS=(-isysroot "$SDK" -fobjc-arc -fblocks -O2
  -Wall -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations
  -Wno-nullability-completeness -Wno-objc-designated-initializers -Wno-unused-parameter
  -fobjc-weak)

compile() {
  local source="$1" object="$2" triple="$3"
  "$CC" -target "$triple" "${BASE_FLAGS[@]}" -c "$source" -o "$object"
}
link_dylib() {
  local triple="$1" output="$2"; shift 2
  "$CC" -target "$triple" -isysroot "$SDK" -Wl,-undefined,dynamic_lookup -dynamiclib \
    -o "$output" "$@" -framework UIKit -framework Foundation -framework AudioToolbox \
    -framework IOKit -Wl,-install_name,/var/jb/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib
}
link_bundle() {
  local triple="$1" output="$2"; shift 2
  "$CC" -target "$triple" -isysroot "$SDK" -Wl,-undefined,dynamic_lookup -bundle \
    -o "$output" "$@" -framework UIKit -framework Foundation
}

for arch in arm64 arm64e; do
  triple="${arch}-apple-ios16.0"
  echo "== compiling tweak: $triple"
  compile "$SRC/Tweak.m" "$OUT/obj/Tweak-$arch.o" "$triple"
  compile "$SRC/PGPrefs.m" "$OUT/obj/PGPrefs-$arch.o" "$triple"
  link_dylib "$triple" "$OUT/GrabberCard-$arch.dylib" "$OUT/obj/Tweak-$arch.o" "$OUT/obj/PGPrefs-$arch.o"
  echo "== compiling settings: $triple"
  compile "$SRC/Settings/Settings.m" "$OUT/obj/Settings-$arch.o" "$triple"
  compile "$SRC/PGPrefs.m" "$OUT/obj/Prefs-$arch.o" "$triple"
  link_bundle "$triple" "$OUT/GrabberCardSettings-$arch" "$OUT/obj/Settings-$arch.o" "$OUT/obj/Prefs-$arch.o"
done

$LIPO -create "$OUT/GrabberCard-arm64.dylib" "$OUT/GrabberCard-arm64e.dylib" -output "$OUT/GrabberCard.dylib"
$LIPO -create "$OUT/GrabberCardSettings-arm64" "$OUT/GrabberCardSettings-arm64e" -output "$OUT/GrabberCardSettings"
$LIPO -verify_arch arm64 arm64e "$OUT/GrabberCard.dylib"
$LIPO -verify_arch arm64 arm64e "$OUT/GrabberCardSettings"
"$LDID" -S "$OUT/GrabberCard.dylib"
"$LDID" -S "$OUT/GrabberCardSettings"

STAGE="$OUT/stage"
mkdir -p "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$STAGE/var/jb/Library/PreferenceBundles/GrabberCardSettings.bundle"
mkdir -p "$STAGE/var/jb/Library/PreferenceLoader/Preferences" "$STAGE/DEBIAN"
cp "$OUT/GrabberCard.dylib" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib"
cp "$SRC/GrabberCard.plist" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/GrabberCard.plist"
cp "$OUT/GrabberCardSettings" "$STAGE/var/jb/Library/PreferenceBundles/GrabberCardSettings.bundle/GrabberCardSettings"
cp "$SRC/Settings/Info.plist" "$STAGE/var/jb/Library/PreferenceBundles/GrabberCardSettings.bundle/Info.plist"
cp "$SRC/layout/Library/PreferenceLoader/Preferences/com.grabbercard.plist" "$STAGE/var/jb/Library/PreferenceLoader/Preferences/com.grabbercard.plist"
if [ -f "$SRC/Settings/GrabberCard.png" ]; then cp "$SRC/Settings/GrabberCard.png" "$STAGE/var/jb/Library/PreferenceBundles/GrabberCardSettings.bundle/GrabberCard.png"; fi
cp "$SRC/control" "$STAGE/DEBIAN/control"
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$PKG/GrabberCard_rootless.deb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
dpkg-deb -R "$PKG/GrabberCard_rootless.deb" "$WORK/root"
ROOTPKG="$WORK/root"
cp -a "$ROOTPKG/var/jb/." "$ROOTPKG/"
rm -rf "$ROOTPKG/var"
chmod -R a+rX,u+w "$ROOTPKG"
chmod 0755 "$ROOTPKG/DEBIAN"
DYLIB="$ROOTPKG/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib"
PREFS="$ROOTPKG/Library/PreferenceBundles/GrabberCardSettings.bundle/GrabberCardSettings"

rewrite_deps() {
  local bin="$1" dep
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      *[Ss]ubstrate*) install_name_tool -change "$dep" '@loader_path/.jbroot/usr/lib/libsubstrate.dylib' "$bin" ;;
      /var/jb/*) install_name_tool -change "$dep" "@loader_path/.jbroot${dep#/var/jb}" "$bin" ;;
      @rpath/*) install_name_tool -change "$dep" "@loader_path/.jbroot/usr/lib/${dep#@rpath/}" "$bin" ;;
    esac
  done < <(otool -L "$bin" | tail -n +2 | python3 -c 'import sys; print("".join(x.split()[0]+"\n" for x in sys.stdin if x.split()))')
}
rewrite_deps "$DYLIB"
rewrite_deps "$PREFS"
install_name_tool -id '@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib' "$DYLIB"
"$LDID" -S "$DYLIB"
"$LDID" -S "$PREFS"
python3 - "$ROOTPKG/DEBIAN/control" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
s=s.replace('Version: 1.0.3\n','Version: 1.0.3+roothide\n')
s=s.replace('Architecture: iphoneos-arm64\n','Architecture: iphoneos-arm64e\n')
p.write_text(s)
PY
dpkg-deb -Zgzip --root-owner-group -b "$ROOTPKG" "$DIST/GrabberCard_1.0.3+roothide_iphoneos-arm64e.deb"

$LIPO -verify_arch arm64 arm64e "$OUT/GrabberCard.dylib"
$LIPO -verify_arch arm64 arm64e "$OUT/GrabberCardSettings"
mkdir -p "$WORK/verify"
dpkg-deb -x "$DIST/GrabberCard_1.0.3+roothide_iphoneos-arm64e.deb" "$WORK/verify"
V="$WORK/verify"
$LIPO -verify_arch arm64 arm64e "$V/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib"
$LIPO -verify_arch arm64 arm64e "$V/Library/PreferenceBundles/GrabberCardSettings.bundle/GrabberCardSettings"
python3 - "$V/Library/MobileSubstrate/DynamicLibraries/GrabberCard.dylib" "$V/Library/PreferenceBundles/GrabberCardSettings.bundle/GrabberCardSettings" <<'PY'
import subprocess,sys
for p in sys.argv[1:]:
 o=subprocess.check_output(['otool','-L',p],text=True)
 bad=[x.strip() for x in o.splitlines()[1:] if '/var/jb/' in x]
 if bad: raise SystemExit(f'Unexpected /var/jb dependency in {p}: {bad}')
 print('Dependencies OK:',p)
PY
dpkg-deb -f "$DIST/GrabberCard_1.0.3+roothide_iphoneos-arm64e.deb" Package Version Architecture
shasum -a 256 "$DIST/GrabberCard_1.0.3+roothide_iphoneos-arm64e.deb"
echo 'RootHide build and static checks complete.'
