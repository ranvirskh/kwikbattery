#!/bin/bash
#
# One-line KwikBattery installer. Paste into Terminal:
#
#     curl -fsSL https://raw.githubusercontent.com/ranvirskh/kwikbattery/main/install.sh | bash
#
# Downloads the latest release from GitHub, checks its signature, puts it in
# Applications, sets up iPhone and iPad battery levels (libimobiledevice via
# Homebrew, installing Homebrew first if needed) and opens it. Running it again
# updates an existing copy. Downloading with curl (not a browser) skips the
# Gatekeeper "Open Anyway" steps.
#
set -euo pipefail

REPO="ranvirskh/kwikbattery"
APP="KwikBattery.app"

major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 14 )); then
  echo "KwikBattery needs macOS 14 Sonoma or later (this Mac has $(sw_vers -productVersion))."
  exit 1
fi

# Update a copy in ~/Applications in place; otherwise use /Applications when
# this account can write to it (admin accounts can), else ~/Applications.
if [[ -d "$HOME/Applications/$APP" ]]; then
  DEST="$HOME/Applications"
elif [[ -w /Applications ]]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

echo "==> Finding the latest KwikBattery release"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*KwikBattery[^"]*\.zip"' \
  | head -1 | sed -E 's/.*"(https:[^"]+)"$/\1/')"
case "$URL" in
  "https://github.com/$REPO/releases/download/"*) ;;
  *) echo "Couldn't find the download on GitHub. Get it from https://github.com/$REPO/releases"; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading $(basename "$URL")"
curl -fL --progress-bar -o "$TMP/KwikBattery.zip" "$URL"
ditto -xk "$TMP/KwikBattery.zip" "$TMP/unzipped"
if [[ ! -d "$TMP/unzipped/$APP" ]]; then
  echo "The download didn't contain $APP."
  exit 1
fi
codesign --verify "$TMP/unzipped/$APP"

echo "==> Installing to $DEST"
osascript -e 'quit app "KwikBattery"' >/dev/null 2>&1 || true
pkill -x KwikBattery >/dev/null 2>&1 || true
rm -rf "${DEST:?}/$APP"
ditto "$TMP/unzipped/$APP" "$DEST/$APP"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

# --- iPhone and iPad battery levels -------------------------------------------
# KwikBattery reads them with libimobiledevice's idevice_id / ideviceinfo,
# which come from Homebrew. A failure here doesn't undo the app install.
for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.homebrew/bin"; do
  if [[ -x "$dir/brew" ]]; then export PATH="$dir:$PATH"; fi
done

setup_iphone_support() {
  if command -v idevice_id >/dev/null 2>&1 && command -v ideviceinfo >/dev/null 2>&1; then
    echo "==> iPhone and iPad support is already installed"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "==> Installing Homebrew (needed for iPhone and iPad battery levels)"
    echo "    Enter your Mac login password when asked. Nothing appears as you type;"
    echo "    press Return when you're done. This step can take a few minutes."
    sudo -v < /dev/tty || return 1
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      < /dev/null || return 1
    for dir in /opt/homebrew/bin /usr/local/bin; do
      if [[ -x "$dir/brew" ]]; then export PATH="$dir:$PATH"; fi
    done
    command -v brew >/dev/null 2>&1 || return 1
  fi
  echo "==> Installing iPhone and iPad support (libimobiledevice)"
  brew install libimobiledevice < /dev/null
}

if ! setup_iphone_support; then
  echo ""
  echo "⚠️  iPhone and iPad battery levels couldn't be set up. Everything else works."
  echo "    To try again later:  brew install libimobiledevice"
fi

open "$DEST/$APP"
echo ""
echo "✅ KwikBattery is installed in $DEST and running. Click the battery icon in your menu bar."
echo ""
echo "For your iPhone or iPad: plug it in once and tap Trust, and allow KwikBattery in"
echo "System Settings › Privacy & Security › Local Network to see it over Wi-Fi."
