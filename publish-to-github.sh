#!/bin/bash
#
# Publish KwikBattery to GitHub in one go:
#   • installs the GitHub CLI (via Homebrew) if needed and signs you in
#   • creates the public "kwikbattery" repository (or updates it) and pushes the code
#   • builds a universal release zip and attaches it to a GitHub release
#
# Usage:  bash publish-to-github.sh
# Run it again any time to push new changes and refresh the release download.
#
set -euo pipefail
cd "$(dirname "$0")"

REPO_NAME="kwikbattery"
DESCRIPTION="Free native macOS menu bar app for battery health, live power flow and connected-device batteries."
VERSION="$(grep -E '^VERSION=' build.sh | head -1 | cut -d'"' -f2)"

# --- GitHub CLI ---------------------------------------------------------------
for dir in "$HOME/.homebrew/bin" /opt/homebrew/bin /usr/local/bin; do
  [[ -d "$dir" ]] && export PATH="$dir:$PATH"
done

if ! command -v gh >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew wasn't found. Install the GitHub CLI from https://cli.github.com and run this again."
    exit 1
  fi
  echo "==> Installing the GitHub CLI"
  brew install gh
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "==> Sign in to GitHub (follow the prompts; a browser window will open)"
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git

OWNER="$(gh api user --jq .login)"

# --- Git identity (only if you haven't set one) ---------------------------------
if [[ -z "$(git config --global user.name || true)" ]]; then
  git config --global user.name "$(gh api user --jq '.name // .login')"
fi
if [[ -z "$(git config --global user.email || true)" ]]; then
  git config --global user.email "$(gh api user --jq .id)+$OWNER@users.noreply.github.com"
fi

# --- Commit & push ---------------------------------------------------------------
if [[ ! -d .git ]]; then
  echo "==> Creating the local repository"
  git init -b main
fi
git add -A
git commit -m "KwikBattery $VERSION" || echo "(no new changes to commit)"

if gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  echo "==> Pushing to github.com/$OWNER/$REPO_NAME"
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
  git push -u origin main
else
  echo "==> Creating github.com/$OWNER/$REPO_NAME (public)"
  gh repo create "$REPO_NAME" --public --description "$DESCRIPTION" \
    --source=. --remote=origin --push
fi

# --- Release download --------------------------------------------------------------
echo "==> Building the universal release"
bash build.sh --release
ZIP="release/KwikBattery-$VERSION.zip"

NOTES="Free menu bar battery monitor for macOS 14 Sonoma or later. Universal build — Apple silicon and Intel.

## How to install

**1.** Download **KwikBattery-$VERSION.zip** below. Safari unzips it automatically; in Chrome or Firefox, double-click the .zip in your Downloads folder.

**2.** Drag **KwikBattery.app** into your **Applications** folder.

**3.** Double-click it. macOS will refuse to open it the first time:
- If it says *Apple could not verify \"KwikBattery\" is free of malware* — click **Done** and continue to step 4.
- If it says *\"KwikBattery\" is damaged and can't be opened* — click **Cancel** and use the Terminal method below instead. That wording means macOS won't show an Open Anyway button.

**4.** Approve it:
1. Apple menu → **System Settings**
2. Sidebar → **Privacy & Security**
3. Scroll to the bottom, to the **Security** section
4. Click **Open Anyway** next to *\"KwikBattery\" was blocked to protect your Mac*
5. Authenticate with Touch ID or your login password
6. Click **Open Anyway** in the confirmation dialog

**5.** The battery icon appears in your menu bar. There is no Dock icon and no window — click the menu bar icon.

You only do this once. Updates installed from inside the app skip it.

## Terminal method

Faster, and the required fix if you saw the \"damaged\" message. Open Terminal, paste, press Return:

\`\`\`
xattr -dr com.apple.quarantine /Applications/KwikBattery.app && open /Applications/KwikBattery.app
\`\`\`

## Why

macOS quarantines anything downloaded through a browser and won't launch it unless it's notarized by Apple, which needs a paid developer account. KwikBattery is signed locally instead. The app is not damaged — macOS just can't tie it to a paying developer. All source is in this repo if you'd rather build it yourself."

if gh release view "v$VERSION" --repo "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
  echo "==> Updating release v$VERSION"
  gh release upload "v$VERSION" "$ZIP" --clobber --repo "$OWNER/$REPO_NAME"
else
  echo "==> Publishing release v$VERSION"
  gh release create "v$VERSION" "$ZIP" --repo "$OWNER/$REPO_NAME" \
    --title "KwikBattery $VERSION" --notes "$NOTES"
fi

echo ""
echo "✅ Done: https://github.com/$OWNER/$REPO_NAME"
open "https://github.com/$OWNER/$REPO_NAME"
