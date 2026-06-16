#!/usr/bin/env bash
# Build the widget and install it as a login-start background agent.
set -euo pipefail

LABEL="com.llmwidget"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$REPO_DIR/LLMUsageWidget"
BINARY="$PACKAGE_DIR/.build/release/LLMUsageWidget"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/llm-widget.log"

echo "Building release binary..."
swift build -c release --package-path "$PACKAGE_DIR"

if [[ ! -x "$BINARY" ]]; then
  echo "Build did not produce an executable at $BINARY" >&2
  exit 1
fi

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
        <string>$BINARY</string>
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

echo "Installed and running. Logs: $LOG"
echo "Stop:    launchctl bootout $DOMAIN/$LABEL"
echo "Restart: launchctl kickstart -k $DOMAIN/$LABEL"
