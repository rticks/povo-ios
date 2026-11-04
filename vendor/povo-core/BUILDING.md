# Building for each platform

This environment (Linux/WSL sandbox) has verified `cargo build`/`cargo test`
for the host target and Kotlin/Swift binding generation. It does **not**
have the Windows, Android, or iOS toolchains installed, so the
cross-compiles below are documented but not executed here — run them on a
machine with the relevant SDK.

## Generating bindings

Read this before the per-platform sections: the obvious command silently
does nothing.

### Never hand `uniffi-bindgen` a stripped library

The workspace `[profile.release]` sets `strip = true`, which removes the
`UNIFFI_META_*` symbols `uniffi-bindgen` reads in `--library` mode. Passing
it a stripped `.so`/`.dll`/`.a` **writes zero files and exits 0** — no
error, no warning, so it looks like it succeeded until the host build fails
on missing classes.

Generate from an unstripped library instead. A host debug build is the
simplest source and carries the same metadata:

```sh
cargo build -p povo-core                       # host, debug, symbols intact
cargo run -p povo-core --bin uniffi-bindgen -- generate \
  --library target/debug/libpovo_core.so \
  --language kotlin --out-dir <out-dir>
```

Or keep the release artifact and disable stripping for that build:

```sh
CARGO_PROFILE_RELEASE_STRIP=false cargo build -p povo-core --release
```

The bindings describe the API, not the target, so generating them from the
host library while shipping the stripped per-ABI libraries is correct.

### Kotlin/Android configuration

`crates/povo-core/uniffi.toml` sets `android = true` and
`android_cleaner = true` for the Kotlin backend; `uniffi-bindgen` picks it
up from the crate automatically. Without it the generated Kotlin references
`java.lang.ref.Cleaner` (API 33+) directly and a `minSdk 26` project fails
lint's `NewApi` check — the runtime behavior is correct either way, but the
reference remains. A plain-JVM Kotlin consumer must override the file with
`--config <own.toml>`, because the Android cleaner references `android.*`.

## Windows

The project can use llvm-mingw without an MSVC dependency:

```sh
rustup target add x86_64-pc-windows-gnu
cargo build -p povo-core --release --target x86_64-pc-windows-gnu
# -> target/x86_64-pc-windows-gnu/release/povo_core.dll
```

MSVC works too if preferred: `rustup target add x86_64-pc-windows-msvc`
(needs the MSVC linker from Visual Studio Build Tools).

Generate the C header for a C/C++/C# host from an unstripped library — the
release `.dll` above is stripped, so use the host debug build:

```sh
cargo build -p povo-core
cargo run -p povo-core --bin uniffi-bindgen -- generate \
  --library target/debug/libpovo_core.so \
  --language python --out-dir /tmp/ignored   # any language triggers header emission
# the .h/.modulemap-equivalent for C comes from cbindgen if you add it,
# or call directly against povo_coreFFI symbols using the uniffi C ABI.
```

For a Kotlin/Swift-style ergonomic binding on Windows, uniffi's C# and
Python targets are the closest first-class options; see `uniffi-bindgen
generate --language python|kotlin|swift --help`.

## Android

```sh
cargo install cargo-ndk
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android

cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o app/src/main/jniLibs \
  build -p povo-core --release

# NOT the release .so from the line above — it is stripped, and bindgen
# would emit nothing while exiting 0.
cargo build -p povo-core
cargo run -p povo-core --bin uniffi-bindgen -- generate \
  --library target/debug/libpovo_core.so \
  --language kotlin --out-dir app/src/main/kotlin
```

## iOS

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  cargo build -p povo-core --release --target "$target"
done

# Again from the unstripped host build, not the release .a.
cargo build -p povo-core
cargo run -p povo-core --bin uniffi-bindgen -- generate \
  --library target/debug/libpovo_core.dylib \
  --language swift --out-dir bindings/swift

# Combine device+simulator slices into an XCFramework:
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libpovo_core.a -headers bindings/swift \
  -library target/aarch64-apple-ios-sim/release/libpovo_core.a -headers bindings/swift \
  -output PovoCore.xcframework
```

## Notes

- `panic = "abort"` must **not** be set in the release profile: uniffi's
  generated FFI scaffolding catches Rust panics at the boundary and turns
  them into recoverable errors; with `abort` a panic takes down the whole
  host app instead.
- The generated bindings (`bindings/`, `app/.../jniLibs`) are build
  artifacts — gitignored, regenerate them as part of each platform's build.
- `PovoError::Api` names the server's text `server_message`, not `message`:
  uniffi's Kotlin backend generates an `override val message` on every
  error class, and a variant field called `message` collides with it
  (*Conflicting declarations*). Swift is expected to clash the same way.
