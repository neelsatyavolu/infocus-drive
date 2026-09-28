#!/bin/sh
# Builds "build/InFocus Drive.app" (the Swift menu-bar app plus the bundled
# `infocus` CLI, which runs the local WebDAV helper) and a release zip
# "build/InFocus-Drive-mac.zip". Universal, ad-hoc signed.
#   VERSION=0.1.0 ./build.sh
#   CONFIGURATION=debug ./build.sh   # adds --render-previews (design review)
set -eu
cd "$(dirname "$0")"
VERSION="${VERSION:-0.0.0-dev}"
CONFIGURATION="${CONFIGURATION:-release}"
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
sed "s/__VERSION__/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"
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
