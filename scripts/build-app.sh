#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
BIN_DIR="$(swift build -c release --show-bin-path "$@")"
APP="$PWD/dist/OpenShelf.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OpenShelf" "$APP/Contents/MacOS/OpenShelf"
cp README.md "$APP/Contents/Resources/README.md"
cp Resources/OpenShelf.icns "$APP/Contents/Resources/OpenShelf.icns"
cp Resources/connect.sh "$APP/Contents/Resources/connect.sh"
ENGINE="$PWD/.build/downloads/rclone-v1.75.2-osx-$(uname -m | sed s/x86_64/amd64/)/rclone"
if [ ! -x "$ENGINE" ]; then
  echo "Run scripts/fetch-engine.sh first." >&2
  exit 1
fi
cp "$ENGINE" "$APP/Contents/Resources/rclone"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp "$(dirname "$ENGINE")/README.txt" "$APP/Contents/Resources/rclone-README.txt"
codesign --force --sign - "$APP/Contents/Resources/rclone"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenShelf</string>
<key>CFBundleIdentifier</key><string>org.openshelf.desktop</string>
<key>CFBundleIconFile</key><string>OpenShelf</string>
<key>CFBundleName</key><string>OpenShelf</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><false/>
<key>NSAppleEventsUsageDescription</key><string>Open Terminal for interactive cloud account setup.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
