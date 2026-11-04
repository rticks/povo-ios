#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p artifacts/screenshots
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -I -c 'import json,sys; d=json.load(sys.stdin); devices=[v for k,vs in d["devices"].items() if "iOS" in k for v in vs if v.get("isAvailable") and v["name"].startswith("iPhone")]; assert devices,"No iPhone simulator installed"; print(devices[0]["udid"])')"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b
# Ad-hoc signing gives the simulator real Keychain entitlements without
# an Apple account. It never signs the separately packaged distribution IPA.
set +e
xcodebuild test -project Povo.xcodeproj -scheme Povo -configuration Debug \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" -parallel-testing-enabled NO \
  -derivedDataPath build/Simulator -resultBundlePath build/TestResults.xcresult \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY='-' CODE_SIGN_STYLE=Manual \
  | tee build/simulator-tests.log
test_status=$?
set -e
# Export screenshots after failed assertions too; keep the original test exit.
export_status=0
if [[ -d build/TestResults.xcresult ]]; then
  xcrun xcresulttool export attachments --path build/TestResults.xcresult --output-path artifacts/screenshots || export_status=$?
else
  printf 'No XCTest result bundle was produced.\n' >&2
  export_status=1
fi
if [[ "$test_status" -ne 0 ]]; then exit "$test_status"; fi
exit "$export_status"
