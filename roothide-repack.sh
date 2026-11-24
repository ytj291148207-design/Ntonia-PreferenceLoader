#!/usr/bin/env bash
# 把 rootless 包转换成 RootHide（隐根）包，对齐历史产物 com.netskao.perfectgrabber-1.1-23-roothide.deb 的实际结构：
#   1. 载荷从 var/jb 提升到包根
#   2. substrate 依赖改写成 @loader_path/.jbroot/usr/lib/libsubstrate.dylib
#   3. dylib 的 install name 设成 @loader_path/.jbroot/...；bundle 可执行文件去掉 /var/jb 前缀
#   4. control 改成 Architecture: iphoneos-arm64e，Icon 保持原样不动
#   5. 重新签名并打包
set -euo pipefail

src="${1:?usage: roothide-repack.sh <rootless.deb> <out.deb>}"
dst="${2:?usage: roothide-repack.sh <rootless.deb> <out.deb>}"
ldid="${THEOS:-$HOME/theos}/bin/ldid"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
root="$work/root"
dpkg-deb -R "$src" "$root"

# ---------- 1. 载荷提升 ----------
if [ -d "$root/var/jb" ]; then
  mkdir -p "$root/Library"
  cp -a "$root/var/jb/." "$root/"
  rm -rf "$root/var"
fi

# dpkg-deb -R extracts into the mktemp directory, whose initial mode is 0700.
# Normalize package directories so SpringBoard/preferences can traverse the payload.
# First make every directory traversable and every payload file readable, then
# retain executable bits only on the binaries (and existing executable scripts).
chmod -R a+rX,u+w "$root"
chmod 0755 "$root/DEBIAN"
for d in "$root" "$root/Library" "$root/Library/MobileSubstrate" \
         "$root/Library/MobileSubstrate/DynamicLibraries" \
         "$root/Library/PreferenceBundles" \
         "$root/Library/PreferenceBundles/PerfectGrabberSettings.bundle" \
         "$root/Library/PreferenceLoader" \
         "$root/Library/PreferenceLoader/Preferences"; do
  [ ! -d "$d" ] || chmod 0755 "$d"
done

DYLIB="$root/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.dylib"
PREFS="$root/Library/PreferenceBundles/PerfectGrabberSettings.bundle/PerfectGrabberSettings"

# ---------- 2. 依赖重写 ----------
rewrite_deps() {
  local bin="$1"
  [ -f "$bin" ] || return 0
  chmod 0755 "$bin"
  # otool -L 第一行是二进制自身的 install name，不能当依赖改写
  local ownid deps
  ownid="$(otool -D "$bin" | tail -n +2 | head -n 1 || true)"
  deps="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -v -x -F "$ownid" || true)"
  local dep
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      # CydiaSubstrate / libsubstrate / substrate 各种写法（大小写都覆盖）
      *[Ss]ubstrate*)
        install_name_tool -change "$dep" "@loader_path/.jbroot/usr/lib/libsubstrate.dylib" "$bin"
        echo "dep  $dep -> @loader_path/.jbroot/usr/lib/libsubstrate.dylib"
        ;;
      /var/jb/*)
        install_name_tool -change "$dep" "@loader_path/.jbroot${dep#/var/jb}" "$bin"
        echo "dep  $dep -> @loader_path/.jbroot${dep#/var/jb}"
        ;;
      @rpath/*)
        # rootless 编译出的 @rpath 依赖在隐根里找不到 runpath，落到 .jbroot 下的同名库
        install_name_tool -change "$dep" "@loader_path/.jbroot/usr/lib/${dep#@rpath/}" "$bin"
        echo "dep  $dep -> @loader_path/.jbroot/usr/lib/${dep#@rpath/}"
        ;;
    esac
  done <<< "$deps"
}

# dylib: install name 设为 @loader_path/.jbroot 形式（与历史 roothide 包一致）
rewrite_id_dylib() {
  local bin="$1" newid="$2"
  [ -f "$bin" ] || return 0
  local cur
  cur="$(otool -D "$bin" | tail -n +2 | head -n 1 || true)"
  [ -n "$cur" ] || return 0
  [ "$cur" = "$newid" ] && return 0
  install_name_tool -id "$newid" "$bin"
  echo "id   $cur -> $newid"
}

# bundle 可执行文件: 只去掉 /var/jb 前缀，变成 /Library/...（与历史包一致）
rewrite_id_strip_jb() {
  local bin="$1" newid="$2"
  [ -f "$bin" ] || return 0
  local cur
  cur="$(otool -D "$bin" | tail -n +2 | head -n 1 || true)"
  [ -n "$cur" ] || return 0
  [ "$cur" = "$newid" ] && return 0
  install_name_tool -id "$newid" "$bin"
  echo "id   $cur -> $newid"
}

rewrite_deps "$DYLIB"
rewrite_deps "$PREFS"
rewrite_id_dylib "$DYLIB" "@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/PerfectGrabber.dylib"
rewrite_id_strip_jb "$PREFS" "/Library/PreferenceBundles/PerfectGrabberSettings.bundle/PerfectGrabberSettings"

# ---------- 3. control ----------
ctl="$root/DEBIAN/control"
perl -0pi -e 's/^Architecture:.*$/Architecture: iphoneos-arm64e/m' "$ctl"
# 版本加 +roothide 后缀：两个包版本号不同，切换安装时 dpkg 才认得出是不同的包。
perl -0pi -e 's/^Version:\s*(\S+).*$/Version: $1+roothide/m' "$ctl"
echo "--- control ---"
cat "$ctl"

# ---------- 4. 签名 + 打包 ----------
if [ -f "$DYLIB" ]; then "$ldid" -S "$DYLIB"; fi
if [ -f "$PREFS" ]; then "$ldid" -S "$PREFS"; fi
# 压缩方式与 rootless 包保持一致（theos 默认 lzma），避免部分设备 dpkg 不支持 zstd。
# --root-owner-group 必须加：dpkg-deb -R 解包再重打时属主会变成构建用户（runner/staff 501:20），
# 装到设备上文件属主就错了；加了之后统一为 root:root（iOS 上 gid 0 即 wheel）。
dpkg-deb -Zlzma --root-owner-group -b "$root" "$dst" || dpkg-deb -Zgzip --root-owner-group -b "$root" "$dst"

# ---------- 5. 自检 ----------
echo "--- 架构 ---"
lipo -info "$DYLIB"
echo "--- otool -L ---"
otool -L "$DYLIB"
echo "--- 残留 /var/jb 依赖检查 ---"
if otool -L "$DYLIB" | grep -F '/var/jb/' ; then
  echo "!! 仍有 /var/jb 依赖"; exit 1
fi
echo "--- 载荷根 ---"
find "$root" -mindepth 1 -maxdepth 1
echo "OK $dst"
