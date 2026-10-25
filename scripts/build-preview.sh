#!/bin/bash
# Builds a separate "OpenShelf Preview" app with sample data. It has its own bundle ID,
# never mounts anything, never registers for login, and never reads real configuration.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
BIN_DIR="$(swift build -c release --show-bin-path "$@")"
APP="$PWD/dist/OpenShelf Preview.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OpenShelf" "$APP/Contents/MacOS/OpenShelf"
cp README.md "$APP/Contents/Resources/README.md"
cp Resources/OpenShelf.icns "$APP/Contents/Resources/OpenShelf.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenShelf</string>
<key>CFBundleIdentifier</key><string>org.openshelf.desktop.preview</string>
<key>CFBundleIconFile</key><string>OpenShelf</string>
<key>CFBundleName</key><string>OpenShelf Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0-preview</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSEnvironment</key><dict><key>CLOUDSHELF_PREVIEW</key><string>1</string></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
