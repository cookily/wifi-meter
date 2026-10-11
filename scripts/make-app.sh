#!/bin/bash
# 构建并打包 WiFiMeter.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/WiFiMeter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/WiFiMeter "$APP/Contents/MacOS/WiFiMeter"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP" 2>/dev/null

echo "已生成 $APP"
echo "运行：open \"$APP\"（建议拷贝到 /Applications 后再开机自启）"
