#!/usr/bin/env bash
# Build Ollama Gauge as a signed .app with an embedded WidgetKit extension, install
# it to /Applications, and register a LaunchAgent so it runs at login.
#
# Requires: Xcode 16+, an Apple Development signing identity logged into Xcode
# (Settings > Accounts), and `xcodegen` (brew install xcodegen).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$REPO_DIR/LLMUsageWidget"
LABEL="com.llmwidget"
APP_DISPLAY="Ollama Gauge"
APP="/Applications/$APP_DISPLAY.app"
APP_BINARY="$APP/Contents/MacOS/$APP_DISPLAY"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/llm-widget.log"
DOMAIN="gui/$(id -u)"

command -v xcodegen >/dev/null || { echo "xcodegen not found. Run: brew install xcodegen" >&2; exit 1; }

echo "Generating Xcode project..."
xcodegen generate --spec "$PROJ_DIR/project.yml" --project "$PROJ_DIR"

echo "Building Release (signed, auto-provisioned)..."
xcodebuild -project "$PROJ_DIR/OllamaGauge.xcodeproj" \
  -scheme OllamaGauge -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$PROJ_DIR/build" \
  -allowProvisioningUpdates \
  build >/dev/null

BUILT="$PROJ_DIR/build/Build/Products/Release/Ollama Gauge.app"
if [[ ! -d "$BUILT" ]]; then
  echo "Build did not produce $BUILT" >&2
  exit 1
fi

echo "Stopping the running instance (if any)..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

echo "Installing to $APP ..."
/usr/bin/trash "$APP" 2>/dev/null || true
cp -R "$BUILT" "$APP"

# Nudge the system to register the embedded widget extension. Harmless if it
# already knows about it; not fatal if it fails.
echo "Registering widget extension with pluginkit..."
pluginkit -a "$APP/Contents/PlugIns/OllamaGaugeWidget.appex" 2>/dev/null || true

echo "Writing LaunchAgent to $PLIST ..."
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

launchctl bootstrap "$DOMAIN" "$PLIST"

# Force WidgetKit to pick up the freshly installed extension. The cp above swaps
# the .appex binary, but the running widget extension and chronod keep serving
# the OLD code until they're killed, so a rebuild otherwise shows stale views.
# Killing NotificationCenter just re-renders its UI; all three relaunch on demand.
echo "Reloading widget (killing stale extension + chronod)..."
killall OllamaGaugeWidget chronod NotificationCenter 2>/dev/null || true

echo "Installed $APP and running at login. Logs: $LOG"
echo "Stop:    launchctl bootout $DOMAIN/$LABEL"
echo "Restart: launchctl kickstart -k $DOMAIN/$LABEL"
echo
echo "Add the widget: open Notification Center / desktop edit mode and pick \"Ollama Gauge\"."