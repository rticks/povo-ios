#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p artifacts/screenshots
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -I -c 'import json,sys; d=json.load(sys.stdin); devices=[v for k,vs in d["devices"].items() if "iOS" in k for v in vs if v.get("isAvailable") and v["name"].startswith("iPhone")]; assert devices,"No iPhone simulator installed"; print(devices[0]["udid"])')"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b
xcodebuild test -project Povo.xcodeproj -scheme Povo -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" -parallel-testing-enabled NO \
  -derivedDataPath build/Simulator -resultBundlePath build/TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  | tee build/simulator-tests.log
xcrun xcresulttool export attachments --path build/TestResults.xcresult --output-path artifacts/screenshots
