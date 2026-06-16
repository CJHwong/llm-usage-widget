#!/usr/bin/env bash
# Build the widget as a .app bundle and run it at login via a LaunchAgent.
set -euo pipefail

LABEL="com.llmwidget"
BUNDLE_ID="com.hoss.llmusagewidget"
APP_NAME="LLMUsageWidget"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$REPO_DIR/$APP_NAME"
BINARY="$PACKAGE_DIR/.build/release/$APP_NAME"
APP="/Applications/$APP_NAME.app"
APP_BINARY="$APP/Contents/MacOS/$APP_NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/llm-widget.log"

echo "Building release binary..."
swift build -c release --package-path "$PACKAGE_DIR"

if [[ ! -x "$BINARY" ]]; then
  echo "Build did not produce an executable at $BINARY" >&2
  exit 1
fi

echo "Assembling $APP ..."
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP_BINARY"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>LLM Usage Widget</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
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
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed $APP and running at login. Logs: $LOG"
echo "Stop:    launchctl bootout $DOMAIN/$LABEL"
echo "Restart: launchctl kickstart -k $DOMAIN/$LABEL"
