#!/bin/sh
# Install InFocus for Mac: the Portal in its own window, Mac notifications, and
# your Drive in Finder (the app used to be called InFocus Drive).
#   curl -fsSL <drive>/mac/install.sh | sh
# Downloading with curl (not a browser) means macOS doesn't quarantine the app,
# so it opens without a Gatekeeper prompt. Run it again to update.
# Optional: INFOCUS_VERSION=1.2.3 to pin a release.
set -eu

INFOCUS_SERVER='__INFOCUS_SERVER__'
REPO="neelsatyavolu/infocus-drive"
ASSET="InFocus-Drive-mac.zip"
ZIP_APP="InFocus Drive.app" # the name inside the zip (older copies' updater expects it)
APP_NAME="InFocus.app"
OLD_APP="InFocus Drive.app"
BUNDLE_ID="com.github.neelsatyavolu.infocus-drive"

fail() { printf 'InFocus install: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this installs the Mac app; it only runs on macOS."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 13 ] 2>/dev/null || fail "macOS 13 (Ventura) or later is required."
for tool in curl shasum ditto; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."
done

if [ -n "${INFOCUS_DOWNLOAD_BASE:-}" ]; then
  BASE="$INFOCUS_DOWNLOAD_BASE" # local testing only: checksums come from the same place
elif [ -n "${INFOCUS_VERSION:-}" ]; then
  BASE="https://github.com/$REPO/releases/download/cli-v$INFOCUS_VERSION"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

printf 'Downloading InFocus for Mac…\n'
curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET" || fail "download failed ($BASE/$ASSET)."
curl -fsSL "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS" || fail "checksum download failed."
(cd "$TMP" && grep " $ASSET\$" SHA256SUMS | shasum -a 256 -c - >/dev/null) \
  || fail "checksum mismatch — refusing to install."
ditto -x -k "$TMP/$ASSET" "$TMP/app" || fail "couldn't unpack the app."
[ -d "$TMP/app/$ZIP_APP" ] || fail "the download doesn't contain $ZIP_APP."

# /Applications needs an admin account; everyone else gets ~/Applications.
if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; fi
mkdir -p "$DEST"

# Only this account's copy: other people on a shared Mac keep theirs running.
running() { pgrep -x -U "$(id -u)" InFocusDrive >/dev/null 2>&1; }
if running; then
  printf 'Closing the running app (it unmounts the drive first)…\n'
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  i=0
  while running && [ $i -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
  if running; then
    fail "InFocus is still running. Quit it from the menu bar, then run this again."
  fi
fi

# Copy next to the old app first, so a failed copy never leaves you without one.
NEW="$DEST/.InFocus.app.installing"
rm -rf "$NEW"
ditto "$TMP/app/$ZIP_APP" "$NEW" || { rm -rf "$NEW"; fail "couldn't copy the app into $DEST."; }
rm -rf "$DEST/$APP_NAME"
mv "$NEW" "$DEST/$APP_NAME"
rm -rf "${DEST:?}/$OLD_APP" # replaced by InFocus.app

# Pre-fill this Drive's address unless one is already set.
if ! defaults read "$BUNDLE_ID" serverURL >/dev/null 2>&1; then
  defaults write "$BUNDLE_ID" serverURL "$INFOCUS_SERVER"
fi

open "$DEST/$APP_NAME"
printf '\nInstalled %s in %s.\n' "$APP_NAME" "$DEST"
printf 'Sign in with Google in the InFocus window.\n'
