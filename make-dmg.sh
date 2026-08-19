#!/usr/bin/env bash
# 把已构建的 APIMug.app 打包成 DMG（含 /Applications 快捷方式，拖入即安装；
# 卷图标使用应用图标 AppIcon.icns）
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.1.2}"
APP="build/APIMug.app"
if [[ ! -d "$APP" ]]; then
  echo "未找到 $APP，请先运行 ./build.sh $VERSION 构建应用"
  exit 1
fi

# DMG 卷图标：优先用 icon/dmg-icon.png（转 icns），否则用应用图标
DMG_ICON_PNG="icon/dmg-icon.png"
APP_ICON="$APP/Contents/Resources/AppIcon.icns"
VOLUME_ICON="build/.volume-icon.icns"
STAGE="/tmp/dmg-stage"
TMP_DMG="build/.tmp.dmg"
FINAL_DMG="build/APIMug-v$VERSION-macOS.dmg"

# 把 PNG 转成 icns（iconset 目录必须用项目内路径 —— iconutil 在 /tmp 下会报 Invalid Iconset）
make_icns() {  # $1=png  $2=输出 icns
  local iconset="build/dmg-icon.iconset"
  rm -rf "$iconset" && mkdir -p "$iconset"
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    read -r size name <<< "$spec"
    sips -z "$size" "$size" "$1" --out "$iconset/$name.png" >/dev/null 2>&1
  done
  iconutil -c icns "$iconset" -o "$2"
  rm -rf "$iconset"
}

# 生成卷图标 icns
if [[ -f "$DMG_ICON_PNG" ]]; then
  make_icns "$DMG_ICON_PNG" "$VOLUME_ICON"
  echo "使用 icon/dmg-icon.png 作为卷图标"
else
  cp "$APP_ICON" "$VOLUME_ICON"
  echo "使用应用图标作为卷图标"
fi

# 1. 暂存目录：app + /Applications 快捷方式
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 2. 先建可写临时 DMG
rm -f "$TMP_DMG"
hdiutil create -volname "APIMug" -srcfolder "$STAGE" -ov -format UDRW "$TMP_DMG" >/dev/null

# 3. 挂载，写入卷图标并设置自定义图标标志
MOUNT="/Volumes/APIMug"
hdiutil attach "$TMP_DMG" -nobrowse >/dev/null
cp "$VOLUME_ICON" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT" >/dev/null

# 4. 压缩为最终 DMG
rm -f "$FINAL_DMG"
hdiutil convert "$TMP_DMG" -format UDZO -o "$FINAL_DMG" >/dev/null
rm -f "$TMP_DMG" "$VOLUME_ICON"
rm -rf "$STAGE"

echo "已生成 $FINAL_DMG"
