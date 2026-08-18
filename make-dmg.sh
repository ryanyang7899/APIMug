#!/usr/bin/env bash
# 把已构建的 APIMug.app 打包成 DMG（含 /Applications 快捷方式，拖入即安装）
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.1.1}"
APP="build/APIMug.app"
if [[ ! -d "$APP" ]]; then
  echo "未找到 $APP，请先运行 ./build.sh $VERSION 构建应用"
  exit 1
fi

rm -rf /tmp/dmg-stage
mkdir -p /tmp/dmg-stage
cp -R "$APP" /tmp/dmg-stage/
ln -s /Applications /tmp/dmg-stage/Applications

rm -f "build/APIMug-$VERSION-macOS.dmg"
hdiutil create -volname "APIMug" -srcfolder /tmp/dmg-stage -ov -format UDZO "build/APIMug-$VERSION-macOS.dmg"

rm -rf /tmp/dmg-stage
echo "已生成 build/APIMug-$VERSION-macOS.dmg"
