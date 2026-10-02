#!/bin/sh
# Builds InFocus for Mac (the Portal window, the Finder drive and its bundled
# `infocus` CLI, which runs the local WebDAV helper) and a release zip
# "build/InFocus-Drive-mac.zip". Universal, ad-hoc signed (no push entitlement:
# sign-release.sh adds that with a provisioning profile).
# The bundle inside the zip keeps the name "InFocus Drive.app" because the
# updater in already-installed copies looks for it; the app renames itself to
# InFocus.app on first launch (AppRename.swift).
#   VERSION=0.1.0 PORTAL_URL=https://portal.example.com DRIVE_URL=https://drive.example.com ./build.sh
#   CONFIGURATION=debug ./build.sh   # adds --render-previews (design review)
# PORTAL_URL / DRIVE_URL are optional: without PORTAL_URL the app is Drive only;
# without DRIVE_URL people enter the Drive address on first run.
set -eu
cd "$(dirname "$0")"
VERSION="${VERSION:-0.0.0-dev}"
CONFIGURATION="${CONFIGURATION:-release}"
PORTAL_URL="${PORTAL_URL:-}"
DRIVE_URL="${DRIVE_URL:-}"
for url in "$PORTAL_URL" "$DRIVE_URL"; do
  case "$url" in
    "" | https://* | http://localhost*) ;;
    *) echo "PORTAL_URL and DRIVE_URL must be https:// origins (http only for localhost)" >&2; exit 2 ;;
  esac
  # Written into Info.plist with sed: keep to URL-safe characters.
  if printf '%s' "$url" | grep -q '[^A-Za-z0-9.:/_-]'; then
    echo "unexpected characters in $url" >&2; exit 2
  fi
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
sed -e "s/__VERSION__/$VERSION/g" -e "s|__PORTAL_URL__|$PORTAL_URL|g" -e "s|__DRIVE_URL__|$DRIVE_URL|g" \
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
