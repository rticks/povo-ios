#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/vendor/povo-core"
OUT="$ROOT/build"
GEN="$ROOT/Generated"
mkdir -p "$OUT" "$GEN"
export CARGO_TARGET_DIR="$OUT/rust"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo build --locked --manifest-path "$CORE/Cargo.toml" -p povo-core
(cd "$CORE" && cargo run --locked -p povo-core --bin uniffi-bindgen -- generate \
  --library "$CARGO_TARGET_DIR/debug/libpovo_core.dylib" --language swift --out-dir "$GEN")
test -s "$GEN/povo_core.swift"
test -s "$GEN/povo_coreFFI.h"
# Only the XCFramework supplies the Clang module. Duplicate module maps
# in Generated and Xcode's Products/include cause module redefinition errors.
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  cargo build --locked --manifest-path "$CORE/Cargo.toml" -p povo-core --lib --release --target "$target"
done
mkdir -p "$OUT/native-simulator" "$OUT/native-headers"
lipo -create "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libpovo_core.a" \
  "$CARGO_TARGET_DIR/x86_64-apple-ios/release/libpovo_core.a" -output "$OUT/native-simulator/libpovo_core.a"
cp "$GEN/povo_coreFFI.h" "$OUT/native-headers/"
cp "$GEN/povo_coreFFI.modulemap" "$OUT/native-headers/module.modulemap"
# Xcode refuses an existing output. Only remove our generated framework, not source.
if [[ -d "$OUT/PovoCore.xcframework" ]]; then rm -rf "$OUT/PovoCore.xcframework"; fi
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libpovo_core.a" -headers "$OUT/native-headers" \
  -library "$OUT/native-simulator/libpovo_core.a" -headers "$OUT/native-headers" \
  -output "$OUT/PovoCore.xcframework"
