#!/bin/bash
#
# Builds BatteryCap and installs it as /Applications/BatteryCap.app.
# Optional: --persist to also install the LaunchDaemon for boot persistence.
#
# Usage:
#   ./Scripts/install.sh           # just installs the .app
#   ./Scripts/install.sh --persist # also installs LaunchDaemon
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="/Applications/BatteryCap.app"
BINARY_NAME="BatteryCap"

cd "$ROOT_DIR"

echo "==> Building (release, universal binary)..."
# Universal binary: contains both arm64 (Apple Silicon) and x86_64 (Intel).
# One .app runs natively on both architectures — no separate builds needed.
swift build -c release --arch arm64 --arch x86_64

BUILT_BIN="$ROOT_DIR/.build/release/$BINARY_NAME"
if [[ ! -f "$BUILT_BIN" ]]; then
    echo "ERROR: build did not produce $BUILT_BIN" >&2
    exit 1
fi

# Verify universal.
echo "==> Binary arch:"
file "$BUILT_BIN"
if ! file "$BUILT_BIN" | grep -q "universal"; then
    echo "WARNING: binary is not universal. Will only run on one arch."
    echo "To fix: install Xcode with both iOS + macOS SDK components."
fi

echo "==> Packaging into $APP_PATH..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BUILT_BIN" "$APP_PATH/Contents/MacOS/$BINARY_NAME"
chmod 755 "$APP_PATH/Contents/MacOS/$BINARY_NAME"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BatteryCap</string>
    <key>CFBundleIdentifier</key>
    <string>com.ebowwa.battery-cap</string>
    <key>CFBundleName</key>
    <string>BatteryCap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Clear quarantine attr so double-click works without Gatekeeper complaints.
xattr -cr "$APP_PATH" 2>/dev/null || true

echo "==> Installed. Launch with: open $APP_PATH"

if [[ "${1:-}" == "--persist" ]]; then
    echo "==> Installing LaunchDaemon (will prompt for sudo)..."
    BINARY_PATH="$APP_PATH/Contents/MacOS/$BINARY_NAME"
    PLIST_PATH="/Library/LaunchDaemons/com.ebowwa.battery-cap.plist"
    CONF_PATH="/usr/local/etc/battery-cap.conf"

    # Write the daemon plist.
    sudo tee "$PLIST_PATH" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ebowwa.battery-cap</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY_PATH</string>
        <string>--boot-apply</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST

    sudo chown root:wheel "$PLIST_PATH"
    sudo chmod 644 "$PLIST_PATH"

    # Pre-seed the config with 60% if no cap set yet, so --boot-apply has
    # something to do on first boot. User can change via menu later.
    if [[ ! -f "$CONF_PATH" ]]; then
        echo "==> Seeding config with 60% default at $CONF_PATH"
        sudo mkdir -p "$(dirname "$CONF_PATH")"
        echo "60" | sudo tee "$CONF_PATH" >/dev/null
        sudo chmod 644 "$CONF_PATH"
    fi

    # Upgrade-safe load: bootout first if the v0.1 daemon is already loaded
    # with the old plist (no StartInterval), then bootstrap the new one.
    sudo launchctl bootout system/com.ebowwa.battery-cap 2>/dev/null || true
    sudo launchctl bootstrap system/com.ebowwa.battery-cap "$PLIST_PATH" 2>/dev/null \
        || sudo launchctl load -w "$PLIST_PATH"

    echo "==> LaunchDaemon installed. Cap will re-apply on every boot."
    echo "==> First-time cap application (will prompt for sudo again)..."
    sudo "$BINARY_PATH" --boot-apply
    echo "==> Done. Open BatteryCap.app to manage from the menu bar."
fi
