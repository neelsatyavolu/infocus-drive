#!/usr/bin/env bash
# Build InFocus Portal for iPhone and iPad, sign it for the App Store and
# upload it to TestFlight.
#
#   ios/scripts/release-ios.sh              # archive + upload to App Store Connect
#   ios/scripts/release-ios.sh --no-upload  # archive + export ios/build/InFocusPortal.ipa only
#   VERSION=1.0.1 ios/scripts/release-ios.sh
#
# Needs the release Xcode (App Store Connect rejects beta-Xcode builds),
# xcodegen, Node and the 1Password CLI signed in. Credentials never touch this
# repo: they're read from 1Password at run time. Settings come from the
# environment or from ios/release.env (gitignored), for example:
#   OP_ACCOUNT=<1Password account>      APPLE_VAULT=<vault>
#   IOS_CERT_ITEM=<item holding the Apple Distribution .p12 and its "password">
#   IOS_CERT_FILE=<the .p12 attachment's name>   (default AppleDistribution_<team>.p12)
#   ASC_KEY_ITEM=<item holding "Key ID", "issuer id" and AuthKey_<KeyID>.p8>
#   APPLE_TEAM_ID=<team>
#   PORTAL_URL=https://portal.example.com   DRIVE_URL=https://drive.example.com
set -euo pipefail

UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

IOS="$(cd "$(dirname "$0")/.." && pwd)"
cd "$IOS"
# shellcheck disable=SC1091
[ -f release.env ] && set -a && . ./release.env && set +a

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
case "$DEVELOPER_DIR" in
  *beta*) echo "error: $DEVELOPER_DIR is a beta Xcode; App Store Connect rejects its builds" >&2; exit 1 ;;
esac

for name in APPLE_VAULT IOS_CERT_ITEM ASC_KEY_ITEM APPLE_TEAM_ID PORTAL_URL; do
  [ -n "${!name:-}" ] || { echo "error: set $name (see the top of this script)" >&2; exit 2; }
done
export APPLE_VAULT IOS_CERT_ITEM ASC_KEY_ITEM OP_ACCOUNT="${OP_ACCOUNT:-}"

# Hosts for Config/Portal.xcconfig: https origins only, URL-safe characters.
host_of() {
  case "$1" in
    "") echo "" ;;
    https://*) printf '%s' "${1#https://}" | cut -d/ -f1 ;;
    *) echo "error: $2 must be an https:// origin" >&2; exit 2 ;;
  esac
}
PORTAL_HOST="$(host_of "$PORTAL_URL" PORTAL_URL)"
DRIVE_HOST="$(host_of "${DRIVE_URL:-}" DRIVE_URL)"
for value in "$PORTAL_HOST" "$DRIVE_HOST"; do
  if printf '%s' "$value" | grep -q '[^A-Za-z0-9.:-]'; then echo "error: unexpected characters in $value" >&2; exit 2; fi
done

op_() { op ${OP_ACCOUNT:+--account "$OP_ACCOUNT"} "$@"; }
# With the 1Password app's CLI integration, signin unlocks this shell (it may ask for Touch ID).
op_ whoami >/dev/null 2>&1 || op_ signin >/dev/null || { echo "error: couldn't sign in to the 1Password CLI" >&2; exit 1; }

BUNDLE_ID="com.infocuspaly.portal"
PROFILE_NAME="InFocus Portal App Store"
CERT_FILE="${IOS_CERT_FILE:-AppleDistribution_${APPLE_TEAM_ID}.p12}"

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/signing.keychain-db"
# Other builds on this Mac edit the same keychain search list concurrently, so
# only ever add or remove our own keychain — never restore a snapshot.
use_keychain() {
  local others
  others="$(security list-keychains -d user | tr -d '"' | xargs -n1 | grep -vxF "$KEYCHAIN" | xargs)"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN" $others
}
cleanup() {
  local others
  others="$(security list-keychains -d user | tr -d '"' | xargs -n1 | grep -vxF "$KEYCHAIN" | xargs)"
  # shellcheck disable=SC2086
  [ -n "$others" ] && security list-keychains -d user -s $others
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "› Generating the Xcode project"
xcodegen --quiet

echo "› Loading the distribution certificate into a temporary keychain"
op_ read "op://$APPLE_VAULT/$IOS_CERT_ITEM/$CERT_FILE" --out-file "$WORK/dist.p12" >/dev/null
P12_PASSWORD="$(op_ read "op://$APPLE_VAULT/$IOS_CERT_ITEM/password")"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/dist.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
unset P12_PASSWORD
# The .p12 carries Apple's intermediate; codesign only finds it on the search list.
use_keychain

echo "› Checking the App Store profile"
PROFILE_UUID="$(node scripts/asc-profile.mjs "$WORK/profile.mobileprovision")"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILES_DIR"
cp "$WORK/profile.mobileprovision" "$PROFILES_DIR/$PROFILE_UUID.mobileprovision"

BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
VERSION_ARGS=()
[ -n "${VERSION:-}" ] && VERSION_ARGS=(MARKETING_VERSION="$VERSION")
echo "› Archiving build $BUILD_NUMBER"
xcodebuild -project InFocusPortal.xcodeproj -scheme InFocusPortal -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/InFocusPortal.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
  INFOCUS_PORTAL_HOST="$PORTAL_HOST" INFOCUS_DRIVE_HOST="$DRIVE_HOST" INFOCUS_TEAM_ID="$APPLE_TEAM_ID" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  archive -quiet

DESTINATION=export
[ "$UPLOAD" = 1 ] && DESTINATION=upload
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>$BUNDLE_ID</key><string>$PROFILE_NAME</string></dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

KEY_ID="$(op_ item get "$ASC_KEY_ITEM" --vault "$APPLE_VAULT" --fields 'label=Key ID' --reveal)"
ISSUER_ID="$(op_ item get "$ASC_KEY_ITEM" --vault "$APPLE_VAULT" --fields 'label=issuer id' --reveal)"
op_ read "op://$APPLE_VAULT/$ASC_KEY_ITEM/AuthKey_${KEY_ID}.p8" --out-file "$WORK/AuthKey.p8" >/dev/null

mkdir -p build
use_keychain # in case another build replaced the search list while we archived
if [ "$UPLOAD" = 1 ]; then echo "› Uploading to App Store Connect"; else echo "› Exporting build/InFocusPortal.ipa"; fi
xcodebuild -exportArchive -archivePath "$WORK/InFocusPortal.xcarchive" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export" \
  -authenticationKeyPath "$WORK/AuthKey.p8" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID" \
  -quiet

if [ "$UPLOAD" = 1 ]; then
  echo "✓ Build $BUILD_NUMBER uploaded. It appears in TestFlight once Apple finishes processing (usually 5–15 minutes)."
else
  cp "$WORK/export/"*.ipa build/InFocusPortal.ipa
  echo "✓ build/InFocusPortal.ipa (build $BUILD_NUMBER)"
fi
