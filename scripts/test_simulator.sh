#!/bin/bash
set -euo pipefail
xcodebuild -version
simulator_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if v.get("isAvailable") and v["name"].startswith("iPhone")]; print(ids[0] if ids else "")')
if [ -z "$simulator_id" ]; then
  echo "No available iPhone simulator. Install an iOS 18+ simulator runtime."
  exit 1
fi
mkdir -p build
xcodebuild -project HomeMovie.xcodeproj -scheme HomeMovie \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -resultBundlePath build/TestResults.xcresult CODE_SIGNING_ALLOWED=NO test 2>&1 | tee build/xcodebuild.log
