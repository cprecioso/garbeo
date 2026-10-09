#!/bin/sh
# Builds build/PaseoSwift-<version>.dmg with the macOS app, ad-hoc signed and not notarized.
#
#   MARKETING_VERSION   overrides the project's version
set -eu
cd "$(dirname "$0")/.."

BUILD=build
rm -rf "$BUILD"

xcodebuild archive \
  -project App/PaseoSwift.xcodeproj -scheme PaseoSwift \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD/PaseoSwift.xcarchive" \
  -derivedDataPath "$BUILD/DerivedData" \
  -skipPackagePluginValidation \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"}

APP="$BUILD/PaseoSwift.xcarchive/Products/Applications/PaseoSwift.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$BUILD/PaseoSwift-$VERSION.dmg"

mkdir "$BUILD/dmg"
ditto "$APP" "$BUILD/dmg/PaseoSwift.app"
ln -s /Applications "$BUILD/dmg/Applications"
diskutil image create from --volumeName PaseoSwift "$BUILD/dmg" "$DMG"

echo "$DMG"
