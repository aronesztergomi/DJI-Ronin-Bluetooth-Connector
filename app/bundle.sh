#!/usr/bin/env bash
# Build Ronin Studio.app.
#
# There is no Xcode on this machine (Command Line Tools only), so the bundle is
# assembled by hand around a SwiftPM executable. That is not a workaround for
# its own sake: the bundle's Info.plist carries NSBluetoothAlwaysUsageDescription,
# and macOS kills any process touching CoreBluetooth without it. A bare
# executable cannot ask for Bluetooth; a bundled one can.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="Ronin Studio.app"
CONFIG="${1:-release}"

echo "==> building rust staticlib (${CONFIG})"
if [ "$CONFIG" = release ]; then
  ( cd "$ROOT" && cargo build --release -p rs3-ffi )
else
  ( cd "$ROOT" && cargo build -p rs3-ffi )
fi

echo "==> building swift executable"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/RS3Studio"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RS3Studio"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Ronin Studio</string>
    <key>CFBundleDisplayName</key>           <string>Ronin Studio</string>
    <key>CFBundleIdentifier</key>            <string>co.rs3studio.app</string>
    <key>CFBundleExecutable</key>            <string>RS3Studio</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>

    <!-- Without this key macOS terminates the process on first CoreBluetooth
         use (TCC, "Bus error: 10"). This is the whole reason for bundling. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Ronin Studio connects to your DJI RS gimbal over Bluetooth to control its motion.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>Ronin Studio connects to your DJI RS gimbal over Bluetooth to control its motion.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. TCC keys are read from the bundle either way, but an
# unsigned binary gets re-prompted on every rebuild as its identity changes.
# The identifier deliberately keeps the old name: macOS keys the
# Bluetooth grant on it, so changing it would only cost a re-prompt.
codesign --force --sign - --identifier co.rs3studio.app "$APP" 2>/dev/null \
  && echo "==> signed (ad-hoc)" \
  || echo "==> unsigned (codesign unavailable)"

echo "==> done: $(pwd)/$APP"
echo "    open \"$APP\"   — approve the Bluetooth prompt on first launch"
