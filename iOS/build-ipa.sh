#!/bin/zsh
# Builds an UNSIGNED Margin.ipa for Sideloadly (Sideloadly signs it with your Apple ID).
# Needs Xcode — runs on GitHub's macOS runners (.github/workflows/iphone-ipa.yml) or any Mac with Xcode.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
OUT="$ROOT/build"
rm -rf "$OUT/ipa" "$OUT/Margin.ipa"

xcodegen
xcodebuild \
  -project MarginPhone.xcodeproj -scheme MarginPhone -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/dd" -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build | tail -20

APP="$OUT/dd/Build/Products/Release-iphoneos/Margin.app"
mkdir -p "$OUT/ipa/Payload"
cp -R "$APP" "$OUT/ipa/Payload/"
(cd "$OUT/ipa" && zip -qry "$OUT/Margin.ipa" Payload)
echo "Built $OUT/Margin.ipa ($(du -h "$OUT/Margin.ipa" | cut -f1))"
