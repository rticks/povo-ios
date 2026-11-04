//! Minimal, non-validating JWT payload reader.
//!
//! The app only ever reads claims out of tokens it just received from its
//! own auth server over TLS, so there is nothing to cryptographically
//! verify here (no signature check, matching the decompiled
//! `com.auth0.android.jwt.JWT` usage, which also never checks the
//! signature client-side).

use base64::Engine;

/// Read a claim as a string.
///
/// Non-string scalars are stringified rather than dropped. An earlier
/// `as_str()`-only version returned `None` for every numeric claim, which
/// made `exp`/`iat` unreadable and pushed hosts into decoding the token a
/// second time themselves. See [`claim_i64`] for the typed variant.
pub fn claim(token: &str, name: &str) -> Option<String> {
    let payload = payload(token)?;
    match payload.get(name)? {
        serde_json::Value::Null => None,
        serde_json::Value::String(text) => Some(text.clone()),
        other => Some(other.to_string()),
    }
}

/// Read a numeric claim (`exp`, `iat`, ...). Numbers encoded as JSON
/// strings are accepted too, since the registered claims are only
/// *conventionally* numeric.
pub fn claim_i64(token: &str, name: &str) -> Option<i64> {
    let payload = payload(token)?;
    match payload.get(name)? {
        serde_json::Value::Number(number) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|value| value as i64)),
        serde_json::Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

fn payload(token: &str) -> Option<serde_json::Value> {
    let payload_b64 = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload_b64)
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a deliberately unsigned fixture at runtime so a JWT-looking
    /// credential is never stored as a source literal.
    fn unsigned_token(payload: &[u8]) -> String {
        let header =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"alg":"none"}"#);
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(payload);
        format!("{header}.{payload}.")
    }

    #[test]
    fn reads_claims() {
        let token =
            unsigned_token(br#"{"iss":"circles","external_id":"user-123","sub":"abc"}"#);
        assert_eq!(claim(&token, "iss").as_deref(), Some("circles"));
        assert_eq!(claim(&token, "external_id").as_deref(), Some("user-123"));
        assert_eq!(claim(&token, "sub").as_deref(), Some("abc"));
        assert_eq!(claim(&token, "missing"), None);
    }

    #[test]
    fn reads_numeric_claims() {
        let token = unsigned_token(br#"{"exp":1893456000,"iat":1893454800}"#);
        assert_eq!(claim(&token, "exp").as_deref(), Some("1893456000"));
        assert_eq!(claim_i64(&token, "exp"), Some(1893456000));
        assert_eq!(claim_i64(&token, "iat"), Some(1893454800));
        assert_eq!(claim_i64(&token, "missing"), None);
    }

    #[test]
    fn reads_numeric_claims_encoded_as_strings() {
        let token = unsigned_token(br#"{"exp":"1893456000","iss":"circles"}"#);
        assert_eq!(claim_i64(&token, "exp"), Some(1893456000));
        // A genuinely non-numeric claim stays unreadable as a number.
        assert_eq!(claim_i64(&token, "iss"), None);
    }

    #[test]
    fn ignores_malformed_tokens() {
        assert_eq!(claim("not-a-jwt", "exp"), None);
        assert_eq!(claim_i64("not-a-jwt", "exp"), None);
        assert_eq!(claim_i64("a.!!!not-base64!!!.c", "exp"), None);
    }
}
