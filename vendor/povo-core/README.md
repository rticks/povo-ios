# povo-core

Unofficial, cross-platform client library for the povo2.0 (`com.kddi.kdla.jp`,
au/KDDI) account API — Windows, Android, and iOS from one Rust core.

Not affiliated with, endorsed by, or supported by KDDI, povo, or
Circles.life. Built for personal account-management/interoperability use.
Endpoints were recovered by reverse-engineering the public APK; see
[`docs/API-REFERENCE.md`](docs/API-REFERENCE.md) for the project-owned API
reference and verification boundaries.

## Layout

```
crates/povo-core/     Rust core: HTTP client, auth flow, models, uniffi bindings
docs/                 Project-owned API reference
```

APK analysis output (jadx/apktool) and captured traffic are kept out of this
repository entirely; only the recovered request contract is published, in
`docs/API-REFERENCE.md`.

## Why Rust + uniffi

One memory-safe core, three platforms:

- **Windows**: build as a native static/dynamic library (`cdylib`) and link
  directly, or call from C#/C++ via the generated C header.
- **Android**: [`cargo-ndk`](https://github.com/bbqsrc/cargo-ndk) builds the
  `.so` for each ABI; `uniffi` generates the Kotlin bindings.
- **iOS**: `cargo build --target aarch64-apple-ios` (+ simulator target)
  produces the static libs for an `XCFramework`; `uniffi` generates the
  Swift bindings.

No GC, no separate reimplementation of the auth/HTTP logic per platform —
only the secure token storage is platform-native (Windows DPAPI, Android
Keystore, iOS Keychain), left to the host app since that's where each OS's
real security guarantees live.

## Status

Implements the login flow (email/SMS OTP, multi-step `login/action`
challenges, token refresh, and post-login device registration) and the
account/billing endpoints confirmed
by prior real-traffic testing (profile, plan usage, referral code, telco
settings, billing timeline + PDF download). Everything else in the
~225-endpoint surface recovered from the APK is reachable through the
generic `get_json` / `post_json` / `post_form` escape hatch pending a
typed wrapper — use the generic route methods for the remaining server-driven
surface, and `get_raw_json` for the non-localized Quilt pages, which the
localized route formula structurally cannot reach. See
`docs/API-REFERENCE.md` and `BUILDING.md` for details, including which
endpoints are confirmed working against a real account and which return
server-side errors.

Build and test locally with:

```sh
cargo test -p povo-core
```
