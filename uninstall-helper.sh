#!/bin/bash
#
# Removes KwikBattery's charge-control helper and puts charging back to normal.
#
#   sudo bash uninstall-helper.sh
#
set -uo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this with sudo:  sudo bash $0"
  exit 1
fi
LABEL="com.kwikbattery.helper"
BIN="/Library/PrivilegedHelperTools/kwikbatteryd"

# Stopping the helper restores normal charging; do it explicitly as well.
launchctl bootout "system/$LABEL" 2>/dev/null || true
[[ -x "$BIN" ]] && "$BIN" --restore || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "$BIN" /var/run/kwikbattery.sock
rm -rf "/Library/Application Support/KwikBattery"
echo "✅ Helper removed. Charging is back to normal."
