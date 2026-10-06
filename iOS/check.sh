#!/bin/zsh
# Type-checks the iPhone app without Xcode by compiling it for Mac Catalyst (same UIKit/AVAudioSession APIs).
set -euo pipefail
cd "$(dirname "$0")/.check"
rm -rf Sources && mkdir -p Sources
rsync -a ../../Sources/MarginKit/ Sources/MarginKit/
rsync -a ../MarginPhone/ Sources/MarginPhone/
SUP="$(xcrun --show-sdk-path)/System/iOSSupport"
swift build --triple arm64-apple-ios26.0-macabi --product MarginPhone \
  -Xswiftc -Fsystem -Xswiftc "$SUP/System/Library/Frameworks" -Xswiftc -I -Xswiftc "$SUP/usr/lib/swift" \
  -Xlinker -F -Xlinker "$SUP/System/Library/Frameworks" -Xlinker -L -Xlinker "$SUP/usr/lib/swift" 2>&1 | grep -E "error|warning: .*(deprecated|unavailable)|complete" | sed "s|$PWD/Sources/|iOS:|" | sort -u; echo "exit: ${pipestatus[1]}"
