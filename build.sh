#!/usr/bin/env bash
# 构建 NewAPIMonitor.app（纯 swiftc，无 Xcode）
set -euo pipefail
cd "$(dirname "$0")"

# 参数：--no-launch 跳过启动；[版本号] 覆盖 CFBundleShortVersionString（默认 1.1.0）
NO_LAUNCH=0
VERSION="1.1.0"
for arg in "$@"; do
  case "$arg" in
    --no-launch) NO_LAUNCH=1 ;;
    *) VERSION="$arg" ;;
  esac
done

APP=APIMug
BUNDLE="build/$APP.app"

rm -rf build
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "==> swiftc 编译..."
swiftc -O \
  -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework AppKit -framework UserNotifications \
  Models.swift ConfigStore.swift APIService.swift \
  NotificationManager.swift MonitorController.swift SettingsWindow.swift AppDelegate.swift Updater.swift LoginItem.swift \
  -o "$BUNDLE/Contents/MacOS/$APP"

echo "==> 写 Info.plist..."
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>APIMug</string>
  <key>CFBundleIdentifier</key><string>com.alfye.NewAPIMonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>API Mug</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 生成应用图标..."
ICONSET="build/AppIcon.iconset"
SRC_ICON="icon/app.png"
if [[ -f "$SRC_ICON" ]]; then
  mkdir -p "$ICONSET"
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    read -r size name <<< "$spec"
    sips -z "$size" "$size" "$SRC_ICON" --out "$ICONSET/$name.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
  echo "已生成 AppIcon.icns"
else
  echo "警告: 未找到 $SRC_ICON，跳过图标"
fi

echo "==> ad-hoc 签名（Apple Silicon 必需）..."
codesign --force --deep --sign - "$BUNDLE"

echo "==> 完成：$BUNDLE"
codesign -dv "$BUNDLE" 2>&1 | grep -E "Identifier|Signature" || true

echo "==> 安装到 /Applications..."
killall APIMug 2>/dev/null || true
rm -rf /Applications/APIMug.app
cp -R "$BUNDLE" /Applications/APIMug.app
codesign --force --deep --sign - /Applications/APIMug.app 2>/dev/null
# 刷新 LaunchServices 注册，避免替换后 open 找不到应用
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/APIMug.app 2>/dev/null || true

if [[ "$NO_LAUNCH" -eq 0 ]]; then
  echo "==> 重启应用..."
  open /Applications/APIMug.app
  echo "Launched /Applications/APIMug.app"
fi
