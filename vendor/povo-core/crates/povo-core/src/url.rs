//! URL construction matching the Android client's `VLI-*` header scheme.
//!
//! Confirmed against the project-owned API reference and authorized traffic as:
//!   with prefix:    {prefix}/{version}/jp/ja/mobile/{relative_path}
//!   without prefix: /{version}/jp/ja/mobile/{relative_path}
//!
//! `telco/settings` is the one confirmed exception that uses locale `en`
//! instead of `ja`; callers pass the locale explicitly for that reason.
//!
//! Not every route is localized, and this formula cannot express the ones
//! that aren't — Quilt pages live directly at `/api/v1/quilt/page/{page}`,
//! so anything routed through here returns `404` for them. Use
//! `PovoClient::get_raw_json`, which skips this construction entirely.

pub const HOST_APP: &str = "https://app.povo.jp";
pub const USER_SERVICE_PREFIX: &str = "/api/v3/user-service";

pub fn build_path(prefix: Option<&str>, version: &str, locale: &str, relative_path: &str) -> String {
    let relative_path = relative_path.trim_start_matches('/');
    match prefix {
        Some(prefix) => format!(
            "{}/{}/jp/{}/mobile/{}",
            prefix.trim_end_matches('/'),
            version,
            locale,
            relative_path
        ),
        None => format!("/{}/jp/{}/mobile/{}", version, locale, relative_path),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_verified_user_service_paths() {
        assert_eq!(
            build_path(Some(USER_SERVICE_PREFIX), "v4", "ja", "otp"),
            "/api/v3/user-service/v4/jp/ja/mobile/otp"
        );
        assert_eq!(
            build_path(Some(USER_SERVICE_PREFIX), "v4", "ja", "users/auth"),
            "/api/v3/user-service/v4/jp/ja/mobile/users/auth"
        );
        assert_eq!(
            build_path(Some("/user-service"), "v5/public", "ja", "users/auth"),
            "/user-service/v5/public/jp/ja/mobile/users/auth"
        );
    }

    #[test]
    fn matches_verified_account_paths() {
        assert_eq!(
            build_path(None, "v4", "ja", "account/usage/plan/get"),
            "/v4/jp/ja/mobile/account/usage/plan/get"
        );
        assert_eq!(
            build_path(None, "v5", "ja", "layout/bills/info"),
            "/v5/jp/ja/mobile/layout/bills/info"
        );
        assert_eq!(
            build_path(None, "v4", "en", "telco/settings"),
            "/v4/jp/en/mobile/telco/settings"
        );
    }
}
