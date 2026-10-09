#!/bin/sh
# Builds build/PaseoSwift-<version>.dmg: the macOS app signed for distribution, in a signed disk image.
#
#   DEVELOPMENT_TEAM    Apple team ID (required)
#   SIGN_IDENTITY       codesign identity (default "Developer ID Application")
#   MARKETING_VERSION   overrides the project's version
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#                       App Store Connect API key; when set, the DMG is notarized and stapled
set -eu
cd "$(dirname "$0")/.."

SIGN_IDENTITY=${SIGN_IDENTITY:-Developer ID Application}
BUILD=build
rm -rf "$BUILD"

xcodebuild archive \
  -project App/PaseoSwift.xcodeproj -scheme PaseoSwift \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD/PaseoSwift.xcarchive" \
  -derivedDataPath "$BUILD/DerivedData" \
  -skipPackagePluginValidation \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?}" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"}

APP="$BUILD/PaseoSwift.xcarchive/Products/Applications/PaseoSwift.app"
codesign --verify --strict --deep "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$BUILD/PaseoSwift-$VERSION.dmg"

mkdir "$BUILD/dmg"
ditto "$APP" "$BUILD/dmg/PaseoSwift.app"
ln -s /Applications "$BUILD/dmg/Applications"
diskutil image create from --volumeName PaseoSwift "$BUILD/dmg" "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo "$DMG"
