#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PovoError {
    #[error("network error: {0}")]
    Network(String),

    /// `code`/`title`/`detail`/`block_until` come from the app's actual
    /// error envelope (`HttpResult.kt` / `p253m3/a.java`), which is richer
    /// than the OpenAPI's simplified `ErrorBody` guess (`{id, message,
    /// success}`) — confirmed via static analysis of the response parser,
    /// not independently traffic-verified field-by-field. See
    /// [`PovoError::from_status_body`] for the envelope shapes that are
    /// unwrapped. `block_until` is an epoch-millisecond deadline the real
    /// client uses to suppress retries after a `503` — surfaced here so
    /// callers can do the same instead of hammering the server.
    ///
    /// The server's text is `server_message`, not `message`, on purpose:
    /// uniffi's Kotlin backend gives every generated error class an
    /// `override val message` holding the Display string, so a variant
    /// field called `message` collides with it and the generated Kotlin
    /// fails to compile (*Conflicting declarations*). Swift is expected to
    /// clash the same way.
    #[error("api error (status {status}): {server_message}")]
    Api {
        status: u16,
        server_message: String,
        code: Option<i64>,
        title: Option<String>,
        detail: Option<String>,
        block_until_epoch_millis: Option<i64>,
    },

    #[error("could not parse server response: {0}")]
    Decode(String),

    #[error("not authenticated: call set_auth_token() or complete login first")]
    Unauthenticated,

    #[error("invalid argument: {0}")]
    InvalidArgument(String),
}

impl PovoError {
    /// Build [`PovoError::Api`] from an HTTP error status and response body.
    ///
    /// Falls back to the raw body as `server_message` when the body isn't
    /// JSON or carries no readable message field.
    pub(crate) fn from_status_body(status: u16, body: String) -> Self {
        let parsed = serde_json::from_str::<serde_json::Value>(&body).ok();
        let envelope = parsed.as_ref().map(error_envelope);
        let get_str = |key: &str| {
            envelope
                .and_then(|o| o.get(key))
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        };
        let get_i64 = |obj: Option<&serde_json::Value>, key: &str| {
            obj.and_then(|o| o.get(key)).and_then(|v| {
                v.as_i64()
                    .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
            })
        };
        let code = get_i64(envelope, "code")
            .or_else(|| get_i64(envelope, "error_code"))
            .or_else(|| get_i64(parsed.as_ref(), "code"));
        let server_message = get_str("message")
            .or_else(|| get_str("ErrInfo"))
            .or_else(|| get_str("description"))
            .or_else(|| get_str("error"))
            .or_else(|| get_str("title"))
            .unwrap_or(body);
        let title = get_str("title").or_else(|| get_str("ErrCode"));
        let detail = get_str("detail").or_else(|| get_str("description"));
        PovoError::Api {
            status,
            server_message,
            code,
            title,
            detail,
            block_until_epoch_millis: get_i64(envelope, "block_until").filter(|v| *v != 0),
        }
    }
}

/// Error bodies do not come back in one shape (`ThrowableUtils.kt` /
/// `com.circles.api.retrofit.exception.a` and `HttpResult.kt` / `p253m3/a`).
/// The fields are sometimes at the top level, sometimes nested one level under
/// `"error"`, `"result"` (`{"success": false, "result": {"message": "Token Expired"}}`),
/// `"failure"` (`{"success": false, "result": null, "failure": {"code": 4221131, "title": "...", "description": "..."}}`),
/// or `"response"`. Descend at most one level, and only into an object.
fn error_envelope(root: &serde_json::Value) -> &serde_json::Value {
    for key in ["error", "result", "failure", "response"] {
        if let Some(nested) = root.get(key) {
            if nested.is_object() {
                return nested;
            }
        }
    }
    root
}

impl From<ureq::Error> for PovoError {
    fn from(e: ureq::Error) -> Self {
        match e {
            ureq::Error::Status(status, response) => {
                PovoError::from_status_body(status, response.into_string().unwrap_or_default())
            }
            other => PovoError::Network(other.to_string()),
        }
    }
}

impl From<std::io::Error> for PovoError {
    fn from(e: std::io::Error) -> Self {
        PovoError::Network(e.to_string())
    }
}

impl From<serde_json::Error> for PovoError {
    fn from(e: serde_json::Error) -> Self {
        PovoError::Decode(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn api_error(status: u16, body: &str) -> (String, Option<i64>, Option<String>) {
        match PovoError::from_status_body(status, body.to_string()) {
            PovoError::Api {
                server_message,
                code,
                detail,
                ..
            } => (server_message, code, detail),
            other => panic!("expected PovoError::Api, got {other:?}"),
        }
    }

    #[test]
    fn reads_a_top_level_envelope() {
        let (message, code, _) = api_error(500, r#"{"message":"error_system_issue","code":42}"#);
        assert_eq!(message, "error_system_issue");
        assert_eq!(code, Some(42));
    }

    #[test]
    fn unwraps_the_error_envelope() {
        let (message, _, detail) =
            api_error(500, r#"{"error":{"message":"error_code_common","detail":"d"}}"#);
        assert_eq!(message, "error_code_common");
        assert_eq!(detail.as_deref(), Some("d"));
    }

    #[test]
    fn unwraps_the_result_envelope() {
        // The shape a real 401 comes back in.
        let (message, _, _) = api_error(401, r#"{"success":false,"result":{"message":"Token Expired"}}"#);
        assert_eq!(message, "Token Expired");
    }

    #[test]
    fn falls_back_to_the_raw_body() {
        let (message, code, _) = api_error(502, "<html>Bad Gateway</html>");
        assert_eq!(message, "<html>Bad Gateway</html>");
        assert_eq!(code, None);
    }

    #[test]
    fn ignores_a_non_object_result() {
        let (message, _, _) = api_error(400, r#"{"message":"top","result":["not","an","object"]}"#);
        assert_eq!(message, "top");
    }

    #[test]
    fn unwraps_the_failure_envelope_and_falls_back_to_description() {
        let body = r#"{"success":false,"result":null,"failure":{"code":4221131,"title":"ERROR_SUBSCRIPTION_BUSINESS_VALIDATION_FAILED","description":"[checkActivateEligibility]: No subscription to activate for the request"}}"#;
        match PovoError::from_status_body(422, body.to_string()) {
            PovoError::Api {
                status,
                server_message,
                code,
                title,
                detail,
                ..
            } => {
                assert_eq!(status, 422);
                assert_eq!(
                    server_message,
                    "[checkActivateEligibility]: No subscription to activate for the request"
                );
                assert_eq!(code, Some(4221131));
                assert_eq!(
                    title.as_deref(),
                    Some("ERROR_SUBSCRIPTION_BUSINESS_VALIDATION_FAILED")
                );
                assert_eq!(
                    detail.as_deref(),
                    Some("[checkActivateEligibility]: No subscription to activate for the request")
                );
            }
            other => panic!("expected PovoError::Api, got {other:?}"),
        }
    }

    #[test]
    fn unwraps_err_info_and_top_level_code() {
        let body = r#"{"code":500,"result":{"ErrCode":"E123","ErrInfo":"Backend failure","description":"desc"}}"#;
        match PovoError::from_status_body(500, body.to_string()) {
            PovoError::Api {
                server_message,
                code,
                title,
                detail,
                ..
            } => {
                assert_eq!(server_message, "Backend failure");
                assert_eq!(code, Some(500));
                assert_eq!(title.as_deref(), Some("E123"));
                assert_eq!(detail.as_deref(), Some("desc"));
            }
            other => panic!("expected PovoError::Api, got {other:?}"),
        }
    }
}
