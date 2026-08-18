#!/usr/bin/env bash
# 把已构建的 APIMug.app 打包成 DMG（含 /Applications 快捷方式，拖入即安装；
# 卷图标使用应用图标 AppIcon.icns）
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.1.1}"
APP="build/APIMug.app"
if [[ ! -d "$APP" ]]; then
  echo "未找到 $APP，请先运行 ./build.sh $VERSION 构建应用"
  exit 1
fi

ICON="$APP/Contents/Resources/AppIcon.icns"
STAGE="/tmp/dmg-stage"
TMP_DMG="build/.tmp.dmg"
FINAL_DMG="build/APIMug-$VERSION-macOS.dmg"

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
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT"
fi
hdiutil detach "$MOUNT" >/dev/null

# 4. 压缩为最终 DMG
rm -f "$FINAL_DMG"
hdiutil convert "$TMP_DMG" -format UDZO -o "$FINAL_DMG" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGE"

echo "已生成 $FINAL_DMG"
