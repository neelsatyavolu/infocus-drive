#!/bin/sh
# Builds InFocus for Mac (the menu-bar app that puts the Drive in Finder, and its
# bundled `infocus` CLI, which runs the local WebDAV helper and Mac backups) and
# a release zip "build/InFocus-Drive-mac.zip". Universal, ad-hoc signed.
# The bundle inside the zip keeps the name "InFocus Drive.app" because the
# updater in already-installed copies looks for it; the app renames itself to
# InFocus.app on first launch (AppRename.swift).
#   VERSION=0.1.0 DRIVE_URL=https://drive.example.com ./build.sh
#   CONFIGURATION=debug ./build.sh   # adds --render-previews (design review)
# DRIVE_URL is optional: without it people enter the Drive address on first run.
# BACKUP_USERS (space-separated Drive usernames) turns on Mac backup for them.
# Only SHA-256 hashes of the names go into the app; it's a feature switch, not
# access control (backups use the person's own Drive permissions).
set -eu
cd "$(dirname "$0")"
VERSION="${VERSION:-0.0.0-dev}"
CONFIGURATION="${CONFIGURATION:-release}"
DRIVE_URL="${DRIVE_URL:-}"
# Old domains (space-separated hosts) whose links, Drive address and sign-in move to these.
LEGACY_HOSTS="${LEGACY_HOSTS:-}"
if printf '%s' "$LEGACY_HOSTS" | grep -q '[^A-Za-z0-9. -]'; then echo "LEGACY_HOSTS: hostnames only" >&2; exit 2; fi
case "$DRIVE_URL" in
  "" | https://* | http://localhost*) ;;
  *) echo "DRIVE_URL must be an https:// origin (http only for localhost)" >&2; exit 2 ;;
esac
# Written into Info.plist with sed: keep to URL-safe characters.
if printf '%s' "$DRIVE_URL" | grep -q '[^A-Za-z0-9.:/_-]'; then
  echo "unexpected characters in DRIVE_URL" >&2; exit 2
fi
BACKUP_USER_HASHES=""
for user in ${BACKUP_USERS:-}; do
  hash="$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]' | shasum -a 256 | cut -d' ' -f1)"
  BACKUP_USER_HASHES="$BACKUP_USER_HASHES $hash"
done
APP="build/InFocus Drive.app"
ZIP="build/InFocus-Drive-mac.zip"
CLI_PKG="github.com/neelsatyavolu/infocus-drive/cli/internal/app"
SWIFT_FLAGS="-c $CONFIGURATION --arch arm64 --arch x86_64"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/cli

(cd ../cli && for arch in arm64 amd64; do
  GOOS=darwin GOARCH=$arch CGO_ENABLED=0 go build -trimpath \
    -ldflags "-s -w -X $CLI_PKG.Version=$VERSION" -o "../mac/build/cli/infocus-$arch" .
done)
lipo -create -output "$APP/Contents/MacOS/infocus" build/cli/infocus-arm64 build/cli/infocus-amd64

# shellcheck disable=SC2086 # word splitting is intended
swift build $SWIFT_FLAGS
# shellcheck disable=SC2086
cp "$(swift build $SWIFT_FLAGS --show-bin-path)/InFocusDrive" "$APP/Contents/MacOS/"
sed -e "s/__VERSION__/$VERSION/g" -e "s|__DRIVE_URL__|$DRIVE_URL|g" -e "s|__LEGACY_HOSTS__|$LEGACY_HOSTS|g" \
  -e "s|__BACKUP_USER_HASHES__|${BACKUP_USER_HASHES# }|g" \
  Info.plist > "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/"
cp Resources/wordmark-dark.png Resources/wordmark-light.png Resources/brand-mark.png \
  Resources/AppIcon.icns "$APP/Contents/Resources/"
# Start at login runs the app with --background through this agent (LoginItem.swift).
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/com.github.neelsatyavolu.infocus-drive.login.plist "$APP/Contents/Library/LaunchAgents/"

codesign --force --options runtime --sign - "$APP/Contents/MacOS/infocus"
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $APP and $ZIP ($VERSION, $CONFIGURATION)"
