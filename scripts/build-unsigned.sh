#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid VERSION\n' >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { printf 'Invalid BUILD_NUMBER\n' >&2; exit 1; }
[[ -d build/PovoCore.xcframework ]] || bash scripts/build-native.sh
xcodegen generate
mkdir -p artifacts build/package/Payload
xcodebuild -project Povo.xcodeproj -scheme Povo -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData -enableCodeCoverage NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build | tee build/device-build.log
APP="$ROOT/build/DerivedData/Build/Products/Release-iphoneos/Povo.app"
test -x "$APP/Povo"
test -x "$APP/PlugIns/PovoWidgets.appex/PovoWidgets"
# ARM64 linkers may emit an ad-hoc signature even with code signing disabled.
# Strip it from the package copy, including the embedded extension.
if [[ -d build/package/Payload/Povo.app ]]; then rm -rf build/package/Payload/Povo.app; fi
cp -R "$APP" build/package/Payload/Povo.app
STAGED="$ROOT/build/package/Payload/Povo.app"
for bundle in "$STAGED/PlugIns/PovoWidgets.appex" "$STAGED"; do
  codesign --remove-signature "$bundle" 2>/dev/null || true
  if codesign -d "$bundle" 2>/dev/null; then
    printf 'Unexpected signature remains: %s\n' "$bundle" >&2; exit 1
  fi
  if [[ -d "$bundle/_CodeSignature" ]]; then rm -rf "$bundle/_CodeSignature"; fi
  if [[ -f "$bundle/embedded.mobileprovision" ]]; then rm "$bundle/embedded.mobileprovision"; fi
done
lipo "$STAGED/Povo" -verify_arch arm64
lipo "$STAGED/PlugIns/PovoWidgets.appex/PovoWidgets" -verify_arch arm64
IPA="$ROOT/artifacts/povo-ios-${VERSION}-unsigned.ipa"
(cd build/package && ditto -c -k --sequesterRsrc --keepParent Payload "$IPA")
(cd artifacts && shasum -a 256 "$(basename "$IPA")" > "$(basename "$IPA").sha256")
python3 -I scripts/verify-ipa.py "$IPA"
printf '\nUnsigned IPA: %s\n' "$IPA"
