#!/usr/bin/env bash
# Developer ID-sign, notarize and staple InFocus Drive for Mac, then replace
# InFocus-Drive-mac.zip (and its line in SHA256SUMS) on a GitHub release that CI
# already published as a pre-release, and make that release Latest. Run it on
# the maintainer's Mac after the release workflow:
#   mac/sign-release.sh cli-v0.4.2
#   mac/sign-release.sh --local 0.4.2   # sign + notarize + staple only, no upload
#
# Credentials never touch this repo or GitHub: they're read from 1Password by
# the shared loader described in ~/Documents/GitHub/APPLE_SIGNING.md (Developer
# ID p12 into a temporary keychain, App Store Connect API key for notarytool).
# Override the loader with INFOCUS_APPLE_CREDS_LOADER, the 1Password account
# with OP_ACCOUNT.
#
# The build needs the addresses it's made for (see build.sh):
#   PORTAL_URL=https://portal.example.com DRIVE_URL=https://drive.example.com mac/sign-release.sh cli-v0.5.0
# (ALLOW_NO_PORTAL=1 builds a Drive-only app on purpose.)
# Mac notifications: MAC_PROVISIONING_PROFILE=/path/to/profile.provisionprofile
# (a Developer ID profile for this bundle ID with Push Notifications; kept in
# 1Password, never in the repo). Without it the app is signed as before and
# just doesn't get notifications. APPLE_TEAM_ID overrides the team read from
# the signing identity.
set -euo pipefail

LOCAL=0
if [ "${1:-}" = "--local" ]; then
  LOCAL=1
  shift
  TAG="cli-v${1:?usage: mac/sign-release.sh --local X.Y.Z}"
else
  TAG="${1:?usage: mac/sign-release.sh cli-vX.Y.Z | --local X.Y.Z}"
fi
case "$TAG" in cli-v*) ;; *) echo "tag must look like cli-v1.2.3" >&2; exit 2 ;; esac
VERSION="${TAG#cli-v}"
if [ -z "${PORTAL_URL:-}" ] && [ "${ALLOW_NO_PORTAL:-}" != 1 ]; then
  echo "set PORTAL_URL (and DRIVE_URL) for the release build, or ALLOW_NO_PORTAL=1 for a Drive-only app" >&2
  exit 2
fi
if [ -n "${MAC_PROVISIONING_PROFILE:-}" ] && [ ! -f "$MAC_PROVISIONING_PROFILE" ]; then
  echo "MAC_PROVISIONING_PROFILE: no such file" >&2
  exit 2
fi
cd "$(dirname "$0")"
APP="build/InFocus Drive.app"
ZIP="build/InFocus-Drive-mac.zip"
LOADER="${INFOCUS_APPLE_CREDS_LOADER:-$HOME/Documents/GitHub/strix/scripts/load-apple-creds.sh}"
if [ "$LOCAL" = 0 ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  gh release view "$TAG" --repo "$REPO" >/dev/null || { echo "no release $TAG yet (wait for CI)" >&2; exit 1; }
fi

echo "== 1/5 load Developer ID + notary credentials (1Password)"
# shellcheck disable=SC1090
source "$LOADER"
trap 'strix_cleanup_apple_creds >/dev/null 2>&1 || true' EXIT
IDENTITY="${APPLE_SIGNING_IDENTITY:?loader did not set APPLE_SIGNING_IDENTITY}"
KEYCHAIN_ARGS=()
[ -n "${STRIX_SIGN_KEYCHAIN:-}" ] && KEYCHAIN_ARGS=(--keychain "$STRIX_SIGN_KEYCHAIN")
KEY_PATH="${APPLE_API_KEY_PATH:?notary key missing}"
KEY_ID="${APPLE_API_KEY_ID:-${APPLE_API_KEY:-}}"
ISSUER="${APPLE_API_ISSUER:?notary issuer missing}"

echo "== 2/5 build $VERSION and sign with $IDENTITY"
VERSION="$VERSION" ./build.sh # PORTAL_URL / DRIVE_URL come from the environment
sign() {
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]}" "$@"
}
# Push needs the aps-environment entitlement, which macOS only accepts with a
# matching provisioning profile inside the app; a restricted entitlement
# without one would stop the app from launching, so it's all or nothing.
ENTITLEMENTS_ARGS=()
if [ -n "${MAC_PROVISIONING_PROFILE:-}" ]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  TEAM_ID="${APPLE_TEAM_ID:-$(printf '%s' "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')}"
  [ -n "$TEAM_ID" ] || { echo "can't read the team ID from the identity; set APPLE_TEAM_ID" >&2; exit 1; }
  ENT_DIR="$(mktemp -d)"
  security cms -D -i "$MAC_PROVISIONING_PROFILE" > "$ENT_DIR/profile.plist"
  PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$ENT_DIR/profile.plist")"
  [ "$PROFILE_APP_ID" = "$TEAM_ID.$BUNDLE_ID" ] \
    || { echo "the provisioning profile is for $PROFILE_APP_ID, not $TEAM_ID.$BUNDLE_ID" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "$ENT_DIR/profile.plist" >/dev/null 2>&1 \
    || { echo "the provisioning profile doesn't include Push Notifications" >&2; exit 1; }
  cp "$MAC_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  cat > "$ENT_DIR/app.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>$TEAM_ID.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM_ID</string>
	<key>com.apple.developer.aps-environment</key>
	<string>production</string>
</dict>
</plist>
PLIST
  ENTITLEMENTS_ARGS=(--entitlements "$ENT_DIR/app.entitlements")
  echo "   with Mac notifications (push entitlement + provisioning profile)"
else
  echo "   without Mac notifications (no MAC_PROVISIONING_PROFILE)"
fi
sign "$APP/Contents/MacOS/infocus" # nested code first, then the bundle
sign ${ENTITLEMENTS_ARGS[@]+"${ENTITLEMENTS_ARGS[@]}"} "$APP"
[ -n "${ENT_DIR:-}" ] && rm -rf "$ENT_DIR"
codesign --verify --strict --deep "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier)="

echo "== 3/5 notarize (Apple usually takes a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
RESULT="$(xcrun notarytool submit "$ZIP" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
  --wait --timeout 45m --output-format json)"
STATUS="$(printf '%s' "$RESULT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
if [ "$STATUS" != "Accepted" ]; then
  ID="$(printf '%s' "$RESULT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  echo "notarization $STATUS" >&2
  [ -n "$ID" ] && xcrun notarytool log "$ID" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" >&2
  exit 1
fi

echo "== 4/5 staple and check Gatekeeper"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tee /dev/stderr | grep -q "Notarized Developer ID"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP" # re-zip with the stapled ticket

if [ "$LOCAL" = 1 ]; then
  echo "Signed and notarized $APP and $ZIP (not uploaded)"
  exit 0
fi

echo "== 5/5 replace the release asset"
WORK="$(mktemp -d)"
gh release download "$TAG" --repo "$REPO" --pattern SHA256SUMS --dir "$WORK"
grep -v " InFocus-Drive-mac.zip\$" "$WORK/SHA256SUMS" > "$WORK/SHA256SUMS.new" || true
(cd build && shasum -a 256 InFocus-Drive-mac.zip) >> "$WORK/SHA256SUMS.new"
mv "$WORK/SHA256SUMS.new" "$WORK/SHA256SUMS"
gh release upload "$TAG" --repo "$REPO" --clobber "$ZIP" "$WORK/SHA256SUMS"
rm -rf "$WORK"
# CI publishes releases as pre-releases; now that the app is notarized, ship it
# (installed apps and the install scripts follow releases/latest).
gh release edit "$TAG" --repo "$REPO" --prerelease=false --latest >/dev/null
echo "Signed, notarized and published InFocus-Drive-mac.zip on $TAG (now Latest)"
