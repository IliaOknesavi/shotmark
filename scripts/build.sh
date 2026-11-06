#!/bin/bash
# Сборка Shotmark.app в ~/Applications. Без Xcode: SwiftPM + ручная упаковка + ad-hoc подпись.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="${APP:-$HOME/Applications/Shotmark.app}"
pkill -x Shotmark 2>/dev/null && sleep 0.5 || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Shotmark "$APP/Contents/MacOS/Shotmark"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.hatiko.shotmark</string>
  <key>CFBundleName</key><string>Shotmark</string>
  <key>CFBundleExecutable</key><string>Shotmark</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Shotmark снимает экран по сочетаниям и по запросам агентов.</string>
</dict></plist>
PLIST
# Самоподписанный сертификат «Shotmark Dev» даёт стабильную подпись: разрешение на запись экрана
# переживает пересборки. Без него — ad-hoc, и macOS спрашивает разрешение после каждой сборки.
ID="${CODESIGN_ID:-Shotmark Dev}"
security find-identity -p codesigning | grep -q "\"$ID\"" || ID="-"
codesign --force --sign "$ID" --identifier com.hatiko.shotmark "$APP"
echo "$APP"
