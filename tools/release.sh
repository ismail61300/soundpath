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
rm -rf build dist
xcodebuild -project SoundPath.xcodeproj -scheme SoundPath -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build -quiet
APP=build/Build/Products/Release/SoundPath.app

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
mkdir -p dist/dmg
cp -R "$APP" dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname SoundPath -srcfolder dist/dmg -ov -format UDZO dist/SoundPath.dmg >/dev/null
rm -rf dist/dmg

if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile soundpath-notary >/dev/null 2>&1; then
  echo "== notarizing"
  xcrun notarytool submit dist/SoundPath.dmg --keychain-profile soundpath-notary --wait
  xcrun stapler staple dist/SoundPath.dmg
fi
echo "done: dist/SoundPath.dmg"
