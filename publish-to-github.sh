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

NOTES="Free menu bar battery monitor for macOS 14 or later (Apple silicon and Intel).

**Install:** unzip, move KwikBattery.app to Applications, and open it. This build isn't notarized by Apple, so macOS will show a warning. Go to System Settings › Privacy & Security and click **Open Anyway**."

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
