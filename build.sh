#!/bin/bash
#
# Build KwikBattery WITHOUT Xcode — only needs Apple's Command Line Tools:
#     xcode-select --install
#
# Usage:
#     bash build.sh             build to ./build/KwikBattery.app and launch it
#     bash build.sh --install   build, copy to ~/Applications and launch it
#     bash build.sh --watch     keep running; rebuild + relaunch whenever the code changes
#     bash build.sh --release   universal (Apple silicon + Intel) build, zipped in ./release/
#
# Optional, for --release with an Apple Developer account:
#     SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#     NOTARY_PROFILE="profile-name"     # created with: xcrun notarytool store-credentials
#
# Every build's output is saved to last-build.log next to this script.
#
set -euo pipefail
cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
LOG="$SCRIPT_DIR/last-build.log"
MODE="${1:-}"

APP_NAME="KwikBattery"
BUNDLE_ID="com.kwikbattery.KwikBattery"
VERSION="1.3"
BUILD_NUMBER="1"
MIN_MACOS="14.0"

SRC="KwikBattery"

# ---------------------------------------------------------------------------
# Watch mode: poll the sources every 2 s; once they've stopped changing for a
# moment (so half-copied updates don't trigger a build), rebuild and relaunch.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "--watch" ]]; then
  fingerprint() {
    cat "$SRC"/*.swift "$SRC"/Info.plist "$SRC"/*.entitlements 2>/dev/null | shasum | cut -d' ' -f1
  }
  echo "👀 Watching $APP_NAME for changes. Leave this window open (Ctrl+C to stop)."
  built=""
  while true; do
    current="$(fingerprint)"
    if [[ "$current" != "$built" ]]; then
      sleep 3
      if [[ "$(fingerprint)" != "$current" ]]; then
        continue   # still changing — wait for it to settle
      fi
      echo ""
      echo "🔨 $(date '+%H:%M:%S') Change detected — building…"
      if bash "$SCRIPT_DIR/build.sh" --install; then
        echo "✅ $(date '+%H:%M:%S') Build succeeded, $APP_NAME relaunched."
      else
        echo "❌ $(date '+%H:%M:%S') Build failed — details in last-build.log. Waiting for the next change…"
      fi
      built="$current"
    fi
    sleep 2
  done
fi

# Save all output of this build to last-build.log (and still show it).
exec > >(tee "$LOG") 2>&1
echo "Build started $(date)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the Command Line Tools first:"
  echo "    xcode-select --install"
  exit 1
fi

SDK="$(xcrun --show-sdk-path --sdk macosx)"

# Build in a temp folder: iCloud-synced folders like Documents attach
# Finder metadata that makes codesign fail ("resource fork ... detritus").
OUT="${TMPDIR:-/tmp}/kwikbattery-build"
APP="$OUT/$APP_NAME.app"

echo "==> Cleaning"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {  # $1 = arch, $2 = output path
  # -parse-as-library: the app uses @main instead of a main.swift file.
  xcrun swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -target "$1-apple-macos$MIN_MACOS" \
    -sdk "$SDK" \
    -module-name "$APP_NAME" \
    "$SRC"/*.swift \
    -o "$2"
}

if [[ "$MODE" == "--release" ]]; then
  echo "==> Compiling Swift (universal: arm64 + x86_64, macOS $MIN_MACOS+)"
  compile arm64 "$OUT/$APP_NAME-arm64"
  compile x86_64 "$OUT/$APP_NAME-x86_64"
  lipo -create "$OUT/$APP_NAME-arm64" "$OUT/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
else
  ARCH="$(uname -m)"
  echo "==> Compiling Swift ($ARCH, macOS $MIN_MACOS+)"
  compile "$ARCH" "$APP/Contents/MacOS/$APP_NAME"
fi

echo "==> Writing Info.plist"
# The Xcode Info.plist uses $(BUILD_SETTING) placeholders; fill them in here.
sed \
  -e "s/\$(DEVELOPMENT_LANGUAGE)/en/g" \
  -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
  -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
  -e "s/\$(PRODUCT_NAME)/$APP_NAME/g" \
  -e "s/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/g" \
  -e "s/\$(MARKETING_VERSION)/$VERSION/g" \
  -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/g" \
  -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/g" \
  "$SRC/Info.plist" > "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Building app icon"
# Xcode's asset compiler isn't available without Xcode, so convert the
# icon PNGs into an .icns file with the built-in iconutil tool instead.
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$SRC/Assets.xcassets/AppIcon.appiconset/"icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

xattr -cr "$APP"
if [[ "$MODE" == "--release" && -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with $SIGN_IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp \
    --entitlements "$SRC/$APP_NAME.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> Signing (ad-hoc, runs on this Mac)"
  codesign --force --sign - \
    --entitlements "$SRC/$APP_NAME.entitlements" \
    "$APP"
fi
codesign --verify "$APP"

if [[ "$MODE" == "--release" ]]; then
  mkdir -p release
  ZIP="release/$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

  if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
  fi

  echo ""
  echo "✅ Release ready: $SCRIPT_DIR/$ZIP"
  echo "   Upload it to a GitHub release (see README)."
  exit 0
fi

echo "==> Live sensor (SMC) check"
"$APP/Contents/MacOS/$APP_NAME" --smc-diag 2>&1 | head -60 || true

if [[ "$MODE" == "--install" ]]; then
  echo "==> Installing to ~/Applications"
  mkdir -p "$HOME/Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$HOME/Applications/$APP_NAME.app"
  ditto --norsrc --noextattr "$APP" "$HOME/Applications/$APP_NAME.app"
  APP="$HOME/Applications/$APP_NAME.app"
else
  # Keep a copy next to the project for convenience.
  rm -rf build
  mkdir -p build
  ditto --norsrc --noextattr "$APP" "build/$APP_NAME.app"
  APP="build/$APP_NAME.app"
fi

echo "==> Launching $APP"
pkill -x "$APP_NAME" 2>/dev/null || true
open "$APP"
echo "Done. Look for the battery icon in your menu bar."
