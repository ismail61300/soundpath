#!/bin/bash
# Local replacement for CI: test, build Release, sign, wrap in a DMG, notarize when possible.
#   tools/release.sh            -> dist/SoundPath.dmg
# Signing: uses the first "Developer ID Application" identity in your keychain (or $SIGN_IDENTITY);
# without one the app is ad-hoc signed. Notarization runs when a notarytool profile named
# "soundpath-notary" exists (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
echo "== tests"
xcodebuild test -project SoundPath.xcodeproj -scheme SoundPath -destination 'platform=macOS' -quiet
echo "== release build"
# Build outside the project: iCloud-synced folders (Desktop/Documents) add xattrs that break codesign.
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
rm -rf dist
xcodebuild -project SoundPath.xcodeproj -scheme SoundPath -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO build -quiet
APP="$BUILD/Build/Products/Release/SoundPath.app"

xattr -cr "$APP"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
if [ -n "$IDENTITY" ]; then
  echo "== signing as $IDENTITY"
  codesign --force --deep --options runtime --entitlements SoundPath/SoundPath.entitlements --timestamp -s "$IDENTITY" "$APP"
else
  echo "== no Developer ID found: ad-hoc signing"
  codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "== dmg"
mkdir -p dist "$BUILD/dmg"
cp -R "$APP" "$BUILD/dmg/"
ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -volname SoundPath -srcfolder "$BUILD/dmg" -ov -format UDZO dist/SoundPath.dmg >/dev/null

if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile soundpath-notary >/dev/null 2>&1; then
  echo "== notarizing"
  xcrun notarytool submit dist/SoundPath.dmg --keychain-profile soundpath-notary --wait
  xcrun stapler staple dist/SoundPath.dmg
fi
echo "done: dist/SoundPath.dmg"
