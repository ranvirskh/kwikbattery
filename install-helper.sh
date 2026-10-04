#!/bin/bash
#
# Installs KwikBattery's charge-control helper (a root LaunchDaemon).
#
#   sudo bash install-helper.sh
#
# The app's "Install Helper…" button runs this same script from inside the app
# bundle (where the compiled helper sits next to it). From a source checkout it
# compiles the helper first. Undo with uninstall-helper.sh.
#
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this with sudo:  sudo bash $0"
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.kwikbattery.helper"
BIN_DST="/Library/PrivilegedHelperTools/kwikbatteryd"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -x "$HERE/kwikbatteryd" ]]; then
  cp "$HERE/kwikbatteryd" "$WORK/kwikbatteryd"
elif [[ -f "$HERE/Helper/main.swift" ]]; then
  echo "==> Compiling the helper"
  SDK="$(xcrun --show-sdk-path --sdk macosx)"
  xcrun swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" \
    "$HERE/Helper/main.swift" "$HERE/KwikBattery/ChargePolicy.swift" \
    -o "$WORK/kwikbatteryd"
else
  echo "Couldn't find the helper binary or its source next to this script."
  exit 1
fi
codesign --force --sign - "$WORK/kwikbatteryd"

echo "==> Checking this Mac (read only)"
"$WORK/kwikbatteryd" --probe || true

echo "==> Installing"
# Stop an older helper first; its shutdown puts charging back to normal.
launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p /Library/PrivilegedHelperTools "/Library/Application Support/KwikBattery"
install -m 755 -o root -g wheel "$WORK/kwikbatteryd" "$BIN_DST"

cat > "$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN_DST</string>
		<string>--daemon</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/var/log/kwikbatteryd.log</string>
	<key>StandardOutPath</key>
	<string>/var/log/kwikbatteryd.log</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

launchctl bootstrap system "$PLIST_DST"
sleep 1
if [[ -S /var/run/kwikbattery.sock ]]; then
  echo "✅ Helper installed and running."
else
  echo "⚠️  Helper installed but its socket isn't up yet. Check /var/log/kwikbatteryd.log"
  exit 1
fi
