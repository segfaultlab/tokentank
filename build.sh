#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/AI额度.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/QuotaFloat "$APP/Contents/MacOS/QuotaFloat"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>QuotaFloat</string>
    <key>CFBundleIdentifier</key><string>local.quotafloat</string>
    <key>CFBundleName</key><string>AI额度</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "已生成 $APP"
