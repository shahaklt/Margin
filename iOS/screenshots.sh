#!/bin/zsh
# Builds the iPhone app for the Simulator, launches each screen with demo data, and saves screenshots.
# Runs in CI (.github/workflows/iphone-ipa.yml) so the phone UI can be checked without a device.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(cd .. && pwd)/build"
mkdir -p "$OUT/shots"
xcodegen
xcodebuild -project MarginPhone.xcodeproj -scheme MarginPhone -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$OUT/sim" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build | tail -5
APP="$OUT/sim/Build/Products/Debug-iphonesimulator/Margin.app"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
phones = [x for k, v in d.items() if "iOS-26" in k for x in v if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]
phones = phones or [x for k, v in d.items() if "iOS" in k for x in v if x["name"].startswith("iPhone")]
print(sorted(phones, key=lambda x: x["name"])[-1]["udid"])')
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryLevel 100 --cellularBars 4 || true
xcrun simctl install "$UDID" "$APP"

shoot() {
  xcrun simctl launch --terminate-running-process "$UDID" com.ltshahak.margin.phone -MarginDemo -MarginScreen "$1" >/dev/null
  sleep "${3:-7}"
  xcrun simctl io "$UDID" screenshot "$OUT/shots/$2.png" >/dev/null
}
for s in home folder notes sheet transcript ask recording settings; do shoot "$s" "$s"; done
xcrun simctl ui "$UDID" appearance dark
shoot home home-dark
shoot notes notes-dark
ls -la "$OUT/shots"
