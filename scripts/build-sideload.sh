#!/usr/bin/env bash
set -euo pipefail

xcodebuild -project HorizonNav.xcodeproj -scheme HorizonNav -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/device \
  -clonedSourcePackagesDirPath build/packages \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS= build

app="$PWD/build/device/Build/Products/Release-iphoneos/HorizonNav.app"
ipa="$PWD/build/HorizonNav-AndroidStyle-unsigned.ipa"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
ditto "$app" "$stage/Payload/HorizonNav.app"
plist="$stage/Payload/HorizonNav.app/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :UIApplicationSceneManifest:UISceneConfigurations' "$plist"
/usr/libexec/PlistBuddy -c 'Delete :CPSupportsInstrumentClusterNavigationScene' "$plist"
binary="$stage/Payload/HorizonNav.app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
test -s "$binary"
test ! -e "$stage/Payload/HorizonNav.app/embedded.mobileprovision"
test ! -d "$stage/Payload/HorizonNav.app/_CodeSignature"
xcrun lipo -verify_arch arm64 "$binary"
xcrun vtool -show-build "$binary" | awk '$1 == "platform" && $2 == "IOS" { ok = 1 } END { exit !ok }'
rm -f "$ipa"
(cd "$stage" && zip -qry "$ipa" Payload)
unzip -tq "$ipa"
unzip -Z1 "$ipa" | awk '$0 == "Payload/HorizonNav.app/Info.plist" { ok = 1 } END { exit !ok }'
shasum -a 256 "$ipa"
