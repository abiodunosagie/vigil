#!/bin/sh
# Build Vigil.app into ~/Applications and install its Claude Code hook.
set -eu

PROJECT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Vigil.app"
BUILD="$PROJECT/build"
# Must match DEFAULT_COMMAND in hooks/install_hooks.py.
HOOK="$HOME/.claude/hooks/vigil-hook.py"
mkdir -p "$BUILD"

echo "Compiling..."
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
  -o "$BUILD/Vigil" "$PROJECT"/mac/*.swift \
  -framework AppKit -framework SwiftUI -framework IOKit

echo "Drawing icon..."
rm -rf "$BUILD/Vigil.iconset"
xcrun swift "$PROJECT/tools/make-icon.swift" "$BUILD/Vigil.iconset"
iconutil -c icns "$BUILD/Vigil.iconset" -o "$BUILD/Vigil.icns"

# Quit the installed copy and give it a moment to exit before its bundle is replaced.
pkill -x Vigil 2>/dev/null || true
sleep 1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Vigil" "$APP/Contents/MacOS/Vigil"
cp "$BUILD/Vigil.icns" "$APP/Contents/Resources/Vigil.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Vigil</string>
  <key>CFBundleDisplayName</key><string>Vigil</string>
  <key>CFBundleIdentifier</key><string>com.abiodun.vigil</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Vigil</string>
  <key>CFBundleIconFile</key><string>Vigil</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Keeps the Mac awake while Claude Code works</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null
echo "Built $APP"

echo "Installing the Claude Code hook..."
mkdir -p "$(dirname "$HOOK")"
cp "$PROJECT/hooks/vigil-hook.py" "$HOOK"
chmod 755 "$HOOK"
python3 "$PROJECT/hooks/install_hooks.py"
echo "Done. New Claude Code sessions report to Vigil; sessions already open need a restart."
