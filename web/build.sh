#!/bin/sh
# Builds the download site for a notarized Garbeo.app: the zipped app, the app icon (light and dark), index.html,
# and a Sparkle appcast.xml.
# Usage: SITE_URL=<site base URL> web/build.sh <path/to/Garbeo.app> <output directory>
# The appcast is signed with the EdDSA key in SPARKLE_PRIVATE_KEY, or in the keychain if that's unset.
set -eu

app=$1
out=$2
web=$(dirname "$0")
# Sparkle needs absolute download URLs
site_url=${SITE_URL:?Set SITE_URL to the URL the site is served from}
site_url=${site_url%/}
info="$app/Contents/Info.plist"
# Icon Composer's ictool. `xcrun ictool` is the one Xcode compiles icons with, which can't export images.
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info")
minimum_system_version=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$info")
commit=$(git -C "$web" rev-parse --short HEAD)

rm -rf "$out"
mkdir -p "$out"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/Garbeo.zip"
for rendition in Default Dark; do
  "$ictool" "$web/../App/Resources/GarbeoNightly.icon" --export-image --output-file "$out/icon-$rendition.png" \
    --platform macOS --rendition "$rendition" --width 128 --height 128 --scale 2 >/dev/null
done
sed -e "s|{{VERSION}}|$version|g" \
    -e "s|{{MINIMUM_SYSTEM_VERSION}}|$minimum_system_version|g" \
    -e "s|{{COMMIT}}|$commit|g" \
    "$web/index.html" >"$out/index.html"
set -- --download-url-prefix "$site_url/" --link "$site_url/" \
  --full-release-notes-url "https://github.com/cprecioso/garbeo/commit/$commit" "$out"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | generate_appcast --ed-key-file - "$@"
else
  generate_appcast "$@"
fi
