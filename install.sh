#!/usr/bin/env bash
# Build the widget as a .app bundle and run it at login via a LaunchAgent.
set -euo pipefail

LABEL="com.llmwidget"
BUNDLE_ID="com.hoss.llmusagewidget"
APP_DISPLAY="Ollama Gauge"
BUILD_EXEC="LLMUsageWidget"   # SwiftPM product + package dir name
BUNDLE_EXEC="Ollama Gauge"    # executable name the OS shows (process, notifications)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$REPO_DIR/$BUILD_EXEC"
BINARY="$PACKAGE_DIR/.build/release/$BUILD_EXEC"
ICON_MASTER="$REPO_DIR/assets/icon-master.png"
APP="/Applications/$APP_DISPLAY.app"
APP_BINARY="$APP/Contents/MacOS/$BUNDLE_EXEC"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/llm-widget.log"

echo "Building release binary..."
swift build -c release --package-path "$PACKAGE_DIR"

if [[ ! -x "$BINARY" ]]; then
  echo "Build did not produce an executable at $BINARY" >&2
  exit 1
fi

echo "Building AppIcon.icns from $ICON_MASTER ..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" "$ICON_MASTER" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z "$((sz*2))" "$((sz*2))" "$ICON_MASTER" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done

echo "Assembling $APP ..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP_BINARY"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY</string>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY</string>
    <key>CFBundleExecutable</key>
    <string>$BUNDLE_EXEC</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST_EOF

echo "Ad-hoc signing the bundle..."
codesign --force --sign - "$APP"

echo "Writing LaunchAgent to $PLIST..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST_EOF

# Reload: kick the old instance out (if any), then start the fresh one.
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout is async; wait for the label to fully unload before re-bootstrapping
for _ in $(seq 1 20); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed $APP and running at login. Logs: $LOG"
echo "Stop:    launchctl bootout $DOMAIN/$LABEL"
echo "Restart: launchctl kickstart -k $DOMAIN/$LABEL"
