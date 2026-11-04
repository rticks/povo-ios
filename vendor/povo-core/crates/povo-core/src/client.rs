use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use base64::Engine;
use rand::RngCore;
use serde_json::json;

use crate::error::PovoError;
use crate::jwt;
use crate::models::*;
use crate::url::{build_path, HOST_APP, USER_SERVICE_PREFIX};

struct State {
    agent: ureq::Agent,
    device_id: String,
    app_version: String,
    auth_token: Option<String>,
    /// "SIN" (service instance number) — the phone line the account/*
    /// endpoints apply to. Auto-populated by `get_profile()` from
    /// `telco_info.service_instance_no`; override with
    /// `set_service_instance_number` for multi-line accounts.
    sin: Option<String>,
    /// Drives the `X-Enable-Auth` header (sent only for `user_type ==
    /// "Guest"`, matching the Android client). Auto-populated by
    /// `get_profile()`.
    user_type: Option<String>,
    user_agent: String,
    /// Caller-supplied headers applied after the built-in ones (see
    /// `PovoClient::set_extra_header`). `BTreeMap` so the emitted order is
    /// deterministic.
    extra_headers: BTreeMap<String, String>,
}

enum Body {
    None,
    Json(serde_json::Value),
    Form(HashMap<String, String>),
}

struct ServiceRoute<'a> {
    prefix: Option<&'a str>,
    version: &'a str,
    locale: &'a str,
    relative_path: &'a str,
}

/// Client for the unofficial povo2.0 (`com.kddi.kdla.jp`) account API.
///
/// Reverse-engineered from the public APK and cross-checked against the
/// project-owned analysis notes. Unaffiliated with
/// KDDI/povo/Circles.life; endpoints and payloads may change without
/// notice. Typed methods cover the stable core; generic route methods cover
/// the wider endpoint surface while preserving the APK's URL rules.
#[derive(uniffi::Object)]
pub struct PovoClient {
    state: Mutex<State>,
}

/// Matches `UUIDGeneratorUtils.kt` (`UUID.randomUUID().getMostSignificantBits()`):
/// a signed 64-bit value, not a millisecond timestamp as earlier (incorrect)
/// prior-research notes assumed. Sent as `uuid` on every request as a
/// client-generated request id.
fn random_request_uuid() -> String {
    let bits: i64 = rand::random();
    bits.to_string()
}

/// Matches the application AB-testing interceptor's UUID.randomUUID().
/// This is a header-level request correlation ID and is distinct from the
/// signed-64-bit `uuid` value injected into JSON/query requests.
fn random_request_id() -> String {
    let mut bytes = [0_u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    // RFC 4122 variant/version bits, matching java.util.UUID's textual form.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

#[uniffi::export]
impl PovoClient {
    #[uniffi::constructor]
    pub fn new(device_id: String, app_version: String) -> Arc<Self> {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(std::time::Duration::from_secs(10))
            .timeout(std::time::Duration::from_secs(30))
            .build();
        // Matches the real format (`G0.java`, DI-provided "User-Agent"
        // string): `selfcare/{app_version} Android/{os} {model}/{locale}`.
        // We're not Android, so this is a deliberate, honest-ish
        // approximation — same shape, a platform tag that says what we
        // actually are — rather than literally impersonating a specific
        // Android build; override with `set_user_agent` if a closer match
        // to the format is needed for compatibility.
        let user_agent = format!("selfcare/{app_version} povo-core/{}", env!("CARGO_PKG_VERSION"));
        Arc::new(Self {
            state: Mutex::new(State {
                agent,
                device_id,
                app_version,
                auth_token: None,
                sin: None,
                user_type: None,
                user_agent,
                extra_headers: BTreeMap::new(),
            }),
        })
    }

    /// Override the `User-Agent` sent with every request (see the
    /// constructor's doc comment for the format the real app uses).
    pub fn set_user_agent(&self, user_agent: String) {
        self.state.lock().unwrap().user_agent = user_agent;
    }

    /// Add (or replace) a header sent with every subsequent request.
    ///
    /// This core builds its own paths, so it deliberately never sends the
    /// app's `VLI-*` routing headers, and the decompiled interceptor chain
    /// showed no `Accept`/`Accept-Language` either. That reasoning holds up,
    /// but without this hook there was no way to *check* whether a given
    /// endpoint's behavior actually depends on those headers.
    ///
    /// Sending povo-native's full set (`Accept`, `Accept-Language`,
    /// `VLI-Version`, `VLI-Localize`) did not change the `HTTP 500` from
    /// `telco/dashboard`, so nothing here is needed for the endpoints this
    /// library covers — the mechanism exists for future probing, and hosts
    /// should default to adding nothing.
    ///
    /// Extra headers are applied last and therefore win over the built-in
    /// ones.
    pub fn set_extra_header(&self, name: String, value: String) {
        self.state.lock().unwrap().extra_headers.insert(name, value);
    }

    /// Restore a previously issued token (e.g. loaded from the host
    /// platform's secure storage: Windows DPAPI, Android Keystore, iOS
    /// Keychain). This library does not persist tokens itself.
    pub fn set_auth_token(&self, token: String) {
        self.state.lock().unwrap().auth_token = Some(token);
    }

    pub fn auth_token(&self) -> Option<String> {
        self.state.lock().unwrap().auth_token.clone()
    }

    /// The current token's expiry claim (`exp` or `expiry_time`), as Unix
    /// epoch seconds.
    ///
    /// Tokens are issued with a 1200-second (20 minute) lifetime, and
    /// [`Self::refresh_token`] hands back the *same* JWT when it's called
    /// before expiry — so a host that wants to refresh on a schedule needs
    /// the deadline rather than a "did the call succeed" signal. `None` when
    /// no token is set or it carries no readable numeric `exp`/`expiry_time`.
    pub fn expires_at(&self) -> Option<i64> {
        let token = self.auth_token()?;
        jwt::claim_i64(&token, "exp").or_else(|| jwt::claim_i64(&token, "expiry_time"))
    }

    pub fn clear_auth_token(&self) {
        self.state.lock().unwrap().auth_token = None;
    }

    pub fn device_id(&self) -> String {
        self.state.lock().unwrap().device_id.clone()
    }

    /// The phone line ("SIN") subsequent `GET` calls are scoped to. `None`
    /// until set explicitly or discovered via `get_profile()`.
    pub fn service_instance_number(&self) -> Option<String> {
        self.state.lock().unwrap().sin.clone()
    }

    /// Override the active phone line for multi-line accounts (the running
    /// Android app calls this "SIN"); `get_profile()` otherwise sets it
    /// automatically from the primary line.
    pub fn set_service_instance_number(&self, sin: Option<String>) {
        self.state.lock().unwrap().sin = sin;
    }

    // ---- Authentication -------------------------------------------------

    /// `POST users/login/action` — first step of login. The server inspects
    /// the identifier (email and/or phone) and returns the ordered list of
    /// challenges (`EMAIL_OTP`, `LOGIN_OTP`, ...) the client must satisfy
    /// before `login()` will succeed. Verified against real traffic.
    ///
    /// `captcha_token`: the reCAPTCHA Enterprise token supplied by the host
    /// UI.  The current app build was observed sending `X-Captcha` on this
    /// request, so a token may be required by production even though older
    /// traffic notes completed this step without one.  Token acquisition is
    /// intentionally platform-specific and is not performed by this core.
    pub fn request_login_action(
        &self,
        email: Option<String>,
        isd_code: Option<String>,
        phone_no: Option<String>,
        captcha_token: Option<String>,
    ) -> Result<LoginActionsResponse, PovoError> {
        // ActionRequest.kt has four nullable fields, and the app's Gson
        // configuration excludes nulls.  In the observed email flow the
        // emitted body is therefore exactly {"email": ...}; device_id is
        // not populated at this stage (it is added to later OTP/device
        // requests where the DTO requires it).
        let mut body_map = serde_json::Map::new();
        if let Some(value) = email {
            body_map.insert("email".to_string(), json!(value));
        }
        if let Some(value) = isd_code {
            body_map.insert("isd_code".to_string(), json!(value));
        }
        if let Some(value) = phone_no {
            body_map.insert("phone_no".to_string(), json!(value));
        }
        let body = serde_json::Value::Object(body_map);
        let value = self.call_user_service(
            "POST",
            false,
            "users/login/action",
            Body::Json(body),
            captcha_token,
        )?;
        Ok(serde_json::from_value(unwrap_result(value))?)
    }

    /// `POST otp` with `request_type=LOGIN_EMAIL_OTP` — sends a one-time
    /// code to `email`. The returned `auth_id` must be echoed back (with
    /// the code the user typed) into [`Self::login`]. Verified.
    pub fn send_email_otp(&self, email: String) -> Result<OtpSendResponse, PovoError> {
        self.send_otp(OtpSendRequest {
            device_id: self.device_id(),
            otp_duration: 15,
            email: Some(email),
            phone_no: None,
            isd_code: None,
            channel: None,
            auth_mode: AuthMode::EnhancedEmailOtp,
            request_type: RequestType::LoginEmailOtp,
        })
    }

    /// `POST otp` with `request_type=LOGIN_MOBILE_OTP` — sends an SMS code.
    /// Used when `request_login_action` also asked for a `LOGIN_OTP` step.
    pub fn send_mobile_otp(
        &self,
        isd_code: String,
        phone_no: String,
    ) -> Result<OtpSendResponse, PovoError> {
        self.send_otp(OtpSendRequest {
            device_id: self.device_id(),
            otp_duration: 15,
            email: None,
            phone_no: Some(phone_no),
            isd_code: Some(isd_code),
            channel: None,
            auth_mode: AuthMode::EnhancedSms,
            request_type: RequestType::LoginMobileOtp,
        })
    }

    /// `POST otp` with `request_type=VERIFY_EMAIL_OTP` — some accounts,
    /// after an `EMAIL_OTP` challenge is satisfied once, require a second
    /// round that sends an SMS code to link/confirm a phone number for the
    /// same login (`LoginFlowViewModel.kt`'s `EMAIL_OTP` branch re-fires
    /// with a phone number once its internal `authId` is already set).
    /// Statically derived; not independently traffic-verified.
    pub fn verify_email_otp(
        &self,
        isd_code: String,
        phone_no: String,
    ) -> Result<OtpSendResponse, PovoError> {
        self.send_otp(OtpSendRequest {
            device_id: self.device_id(),
            otp_duration: 15,
            email: None,
            phone_no: Some(phone_no),
            isd_code: Some(isd_code),
            channel: Some("email".to_string()),
            auth_mode: AuthMode::EnhancedEmailOtp,
            request_type: RequestType::VerifyEmailOtp,
        })
    }

    /// `POST users/auth` — completes login once every challenge from
    /// `request_login_action` has a matching [`AuthChallenge`] (built from
    /// the `auth_id` returned by `send_email_otp`/`send_mobile_otp` plus
    /// the code the user entered). Verified against real traffic; on
    /// success, [`Self::set_auth_token`] is called automatically with the
    /// returned `auth_token`.
    ///
    /// Some app builds additionally require a PIN step
    /// (`validate_pin`) before the token is fully authorized — see that
    /// method's documentation. This has only been confirmed via static
    /// analysis, not live traffic, so treat `pin_token` presence as the
    /// signal for whether it's needed.
    pub fn login(
        &self,
        email_auth: Option<AuthChallenge>,
        mobile_auth: Option<AuthChallenge>,
    ) -> Result<TokenResponse, PovoError> {
        // LoginRequest.kt is serialized by the app's null-excluding Gson
        // configuration.  Do not emit mobile_auth:null (or any other null
        // member); the observed email-only flow contains just device and
        // email_auth.
        let mut body_map = serde_json::Map::new();
        body_map.insert("device".to_string(), self.default_device_meta());
        if let Some(value) = email_auth {
            body_map.insert("email_auth".to_string(), serde_json::to_value(value)?);
        }
        if let Some(value) = mobile_auth {
            body_map.insert("mobile_auth".to_string(), serde_json::to_value(value)?);
        }
        let body = serde_json::Value::Object(body_map);
        // Unlike login/action, otp, and the profile/token calls, the current
        // app routes this method through the public user-service API:
        // /user-service/v5/public/jp/ja/mobile/users/auth.
        let value = self.call_user_service_with(
            "POST",
            false,
            ServiceRoute {
                prefix: Some("/user-service"),
                version: "v5/public",
                locale: "ja",
                relative_path: "users/auth",
            },
            Body::Json(body),
            None,
        )?;
        let token: TokenResponse = serde_json::from_value(unwrap_result(value))?;
        if token.pin_token.is_none() {
            self.set_auth_token(token.auth_token.clone());
        }
        Ok(token)
    }

    /// `POST users/pin/validate` — step-up PIN check some builds require
    /// after `login()` before the session is fully authorized (see
    /// `login()` docs for the verification caveat).
    ///
    /// **Unverified**: recovered only via static analysis of the v1.70.0
    /// `UserService` interface (`VLI-Prefix: /user-service`,
    /// `VLI-Version: v5/public`), and not exercised by the prior
    /// real-traffic research this library otherwise builds on — that
    /// research never saw a PIN challenge in practice. The URL formula
    /// below assumes the same `{prefix}/{version}/jp/{locale}/mobile/{path}`
    /// pattern confirmed for other endpoints, which may not hold for this
    /// one. Treat as a starting point to confirm against real traffic
    /// before relying on it.
    pub fn validate_pin(
        &self,
        pin_token: String,
        pin: String,
        captcha_token: Option<String>,
    ) -> Result<TokenResponse, PovoError> {
        let body = json!({ "pin": pin });
        let path = build_path(Some("/user-service"), "v5/public", "ja", "users/pin/validate");
        let mut body = body;
        inject_uuid_json(&mut body);
        let url = format!("{HOST_APP}{path}");
        let mut req = self.agent_request("POST", &url).set("x-pin-token", &pin_token);
        if let Some(token) = &captcha_token {
            req = req.set("X-Captcha", &captcha_b64(token));
        }
        let value: serde_json::Value = req.send_json(body)?.into_json()?;
        let token: TokenResponse = serde_json::from_value(unwrap_result(value))?;
        self.set_auth_token(token.auth_token.clone());
        Ok(token)
    }

    /// `GET users/token` — refreshes `auth_token` using the current one.
    /// Verified against real traffic.
    pub fn refresh_token(&self) -> Result<TokenResponse, PovoError> {
        let value = self.call_user_service("GET", true, "users/token", Body::None, None)?;
        let token: TokenResponse = serde_json::from_value(unwrap_result(value))?;
        self.set_auth_token(token.auth_token.clone());
        Ok(token)
    }

    /// `PUT users/devices` — registers the current device after login.
    ///
    /// The Android login flow supplies the JWT's `external_id`, the device's
    /// push-registration token, and the fixed mobile defaults recovered from
    /// `DeviceMeta`'s constructor: `token_type=FCM`, `device_type=Mobile`,
    /// `app_type=ecosystem`. The push token is supplied by the host platform;
    /// this core does not contact FCM/APNs itself.
    pub fn update_device(
        &self,
        user_id: String,
        device_token: String,
    ) -> Result<String, PovoError> {
        let body = json!({
            "user_id": user_id,
            "device_id": self.device_id(),
            "device_token": device_token,
            "token_type": "FCM",
            "device_type": "Mobile",
            "app_type": "ecosystem",
        });
        let value = self.call_user_service(
            "PUT",
            true,
            "users/devices",
            Body::Json(body),
            None,
        )?;
        Ok(value.to_string())
    }

    // ---- Account --------------------------------------------------------

    /// `GET users?include_telco=true` — the logged-in user's profile.
    /// Verified against real traffic. Also updates the cached "SIN" (see
    /// [`Self::service_instance_number`]) and `user_type`, matching what
    /// the Android client does on every profile fetch.
    pub fn get_profile(&self) -> Result<UserProfile, PovoError> {
        let value = self.call_user_service("GET", true, "users?include_telco=true", Body::None, None)?;
        let profile = UserProfile::from_json(&value);
        let mut state = self.state.lock().unwrap();
        state.user_type = profile.user_type.clone();
        if let Some(telco) = &profile.telco_info {
            if telco.service_instance_no.is_some() {
                state.sin = telco.service_instance_no.clone();
            }
        }
        Ok(profile)
    }

    /// `GET account/usage/plan/get`. Verified against real traffic. Returns
    /// raw JSON: the plan/usage payload shape varies by plan type and is
    /// not fully modeled here.
    pub fn get_plan_usage_json(&self) -> Result<String, PovoError> {
        self.get_v4_json("account/usage/plan/get")
    }

    /// `GET account/usage/data/details/get?type=rollover&header_carousel=false`.
    /// Statically derived; not independently traffic-verified.
    pub fn get_usage_data_details_json(&self) -> Result<String, PovoError> {
        self.get_v4_json("account/usage/data/details/get?type=rollover&header_carousel=false")
    }

    /// `GET account/plan/details/get`. Statically derived.
    pub fn get_plan_details_json(&self) -> Result<String, PovoError> {
        self.get_v4_json("account/plan/details/get")
    }

    /// `GET account/referral/code/get`. Verified against real traffic.
    pub fn get_referral_code_json(&self) -> Result<String, PovoError> {
        self.get_v4_json("account/referral/code/get")
    }

    /// `GET telco/settings`. Verified against real traffic. Note: this is
    /// the one confirmed endpoint that uses locale `en` rather than `ja`.
    pub fn get_telco_settings_json(&self) -> Result<String, PovoError> {
        let value = self.call_account("GET", "v4", "en", "telco/settings", Body::None)?;
        Ok(value.to_string())
    }

    /// `GET settings/option/list/get?option_id=all&app_type=ecosystem`.
    /// Verified against real traffic.
    pub fn get_settings_options_json(&self) -> Result<String, PovoError> {
        self.get_v4_json("settings/option/list/get?option_id=all&app_type=ecosystem")
    }

    /// `GET layout/bills/info` — the billing timeline, flattened.
    ///
    /// The response has no top-level `bills` or `result` array. An earlier
    /// version of this method looked for one and so returned an empty
    /// vector unconditionally (confirmed on a real account). The actual
    /// top-level keys are `au_services_status`, `banner`, `billing`, `code`,
    /// `instant_charges`, `past_bills`, and `upcoming_bill`, and the bills
    /// live in `past_bills.list[]`.
    ///
    /// This returns the `past_bills`, `upcoming_bill`, and `instant_charges`
    /// entries, each tagged with its [`BillEntry::section`]. Only past bills
    /// carry a downloadable id, so [`BillEntry::bill_id`] is `None` for the
    /// other two sections. The entry shape beyond the id is not modeled, so
    /// `raw_json` carries the whole entry.
    pub fn get_bills_info(&self) -> Result<Vec<BillEntry>, PovoError> {
        let value = self.call_account("GET", "v5", "ja", "layout/bills/info", Body::None)?;
        Ok(parse_bills_info(&unwrap_result(value)))
    }

    /// `GET billing/bills/download/{billId}` — returns the raw (still
    /// password-protected) PDF bytes decoded from the response's
    /// `billing_file.file` base64 field. The password is the account
    /// holder's birth date **with hyphens**, `YYYY-MM-DD`; verified against
    /// a real encrypted PDF, which does not open with the un-hyphenated
    /// `YYYYMMDD` form earlier notes claimed. This library does not decrypt
    /// the PDF itself.
    pub fn download_bill_pdf(&self, bill_id: String) -> Result<Vec<u8>, PovoError> {
        let path = format!("billing/bills/download/{}", urlencode(&bill_id));
        let value = self.call_account("GET", "v4", "ja", &path, Body::None)?;
        let value = unwrap_result(value);
        let b64 = value
            .get("billing_file")
            .and_then(|f| f.get("file"))
            .and_then(|v| v.as_str())
            .ok_or_else(|| PovoError::Decode("missing billing_file.file".into()))?;
        base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| PovoError::Decode(e.to_string()))
    }

    /// `POST /v2/jp/ja/mobile/shop/orders` — places a one-off topping order
    /// (`ShopApi.kt` / `X9/d.java` method `c` with `BuyEntertainerRequest`).
    ///
    /// Note the version is **`v2`**, not the `v4` used by most account routes
    /// or the `v1` used by `subscription/activate` (which is for monthly
    /// partner subscriptions and answers `422` for one-off toppings).
    ///
    /// A `200 OK` does **not** mean a completed purchase when
    /// [`ToppingOrderResult::challenge_url`] is present: the buyer must first
    /// complete 3-D Secure authentication at `challenge_url`, which redirects
    /// to `redirect_url` upon completion.
    pub fn place_topping_order(
        &self,
        sku: String,
        redirect_url: Option<String>,
    ) -> Result<ToppingOrderResult, PovoError> {
        let mut body_map = serde_json::Map::new();
        body_map.insert("sku".to_string(), json!(sku));
        body_map.insert("offer_product".to_string(), serde_json::Value::Null);
        if let Some(url) = redirect_url {
            body_map.insert("redirect_url".to_string(), json!(url));
        }
        let body = serde_json::Value::Object(body_map);
        let value = self.call_account("POST", "v2", "ja", "shop/orders", Body::Json(body))?;
        Ok(serde_json::from_value(unwrap_result(value))?)
    }

    // ---- Generic route access for the wider endpoint surface. -------------

    /// Generic `GET` for endpoints not yet given a typed method above.
    /// `prefix` is `Some("/api/v3/user-service")` or `Some("/user-service")`
    /// for User Service calls, and `None` for the plain account service.
    pub fn get_json(
        &self,
        relative_path: String,
        prefix: Option<String>,
        version: String,
        locale: String,
    ) -> Result<String, PovoError> {
        let value = self.call_route(
            "GET",
            true,
            ServiceRoute {
                prefix: prefix.as_deref(),
                version: &version,
                locale: &locale,
                relative_path: &relative_path,
            },
            Body::None,
            None,
        )?;
        Ok(value.to_string())
    }

    /// Generic `GET` against a host-relative path *as given*, bypassing the
    /// `{prefix}/{version}/jp/{locale}/mobile/{path}` formula that
    /// [`Self::get_json`] and every typed method are built on.
    ///
    /// Some routes are not localized and so are structurally unreachable
    /// through `get_json` — it can only ever produce a `/jp/{locale}/mobile/`
    /// path, which for these returns `404`. Quilt pages are the case that
    /// matters:
    ///
    /// - `/api/v1/quilt/page/user-plan-details-v2` — the **only** source of
    ///   the currently subscribed toppings. Static analysis pointed at
    ///   `account/usage/plan/get`'s `addons_subscribed`, but that field is
    ///   absent from the real response, and `account/plan/details/get` and
    ///   `account/addon/topup/all/get` both return `HTTP 500`.
    /// - `/api/v1/quilt/page/order-history` — the only source of purchase
    ///   history.
    ///
    /// Headers, authentication, and the `sin`/`uuid` decoration rules
    /// (suppressed for `quilt` paths) are applied exactly as for any other
    /// request.
    ///
    /// `absolute_path` is host-relative, not a URL; a value carrying a
    /// scheme is rejected rather than silently pasted onto the host.
    pub fn get_raw_json(&self, absolute_path: String) -> Result<String, PovoError> {
        if absolute_path.contains("://") {
            return Err(PovoError::InvalidArgument(format!(
                "expected a host-relative path, got a URL: {absolute_path}"
            )));
        }
        let path = if absolute_path.starts_with('/') {
            absolute_path
        } else {
            format!("/{absolute_path}")
        };
        let value = self.call_path("GET", true, &path, &path, Body::None, None)?;
        Ok(value.to_string())
    }

    /// `GET /api/v1/quilt/page/{page}` — typed convenience for the quilt
    /// page surface, which is a fixed, non-localized route and so needs no
    /// path assembly by the host.
    ///
    /// Page names confirmed in use: `dashboard-v2` (purchasable topping
    /// catalog under `addon-section` tiles), `user-plan-details-v2` (active
    /// toppings), `order-history` (purchase history), `profile` (masked
    /// credit-card number plus the payment-details change URL — the
    /// `tile-credit-card` tile), and `usage-history?type=DAILY|MONTHLY`.
    ///
    /// If `page` already includes a `?query` suffix (e.g.
    /// `"usage-history?type=DAILY"`), the page segment and query parameters
    /// are encoded separately so `?` and `&` are preserved rather than
    /// percent-encoded into `%3F`. See [`Self::get_quilt_page_with_query_json`]
    /// to pass query parameters as a map.
    pub fn get_quilt_page_json(&self, page: String) -> Result<String, PovoError> {
        let path = build_quilt_page_path(&page, None);
        let value = self.call_path("GET", true, &path, &path, Body::None, None)?;
        Ok(value.to_string())
    }

    /// `GET /api/v1/quilt/page/{page}` with an optional query-parameter map
    /// (`QuiltApi.kt` / `p414u4/x.java`), e.g. `type=DAILY` or `type=MONTHLY`
    /// for `usage-history`.
    pub fn get_quilt_page_with_query_json(
        &self,
        page: String,
        query: Option<HashMap<String, String>>,
    ) -> Result<String, PovoError> {
        let path = build_quilt_page_path(&page, query.as_ref());
        let value = self.call_path("GET", true, &path, &path, Body::None, None)?;
        Ok(value.to_string())
    }

    /// [`Self::get_raw_json`]'s `POST` counterpart, for routes that do not
    /// fit the localized `{prefix}/{version}/jp/{locale}/mobile/{path}`
    /// formula. The known case is the web-front surface used by the
    /// shop.povo.jp SPA, whose routes carry no `mobile` segment:
    ///
    /// - `/api/v3/user-service/v4/jp/ja/webfront/users/session` (POST)
    /// - `/api/v3/user-service/v4/jp/ja/webfront/users/session/update` (POST)
    ///
    /// The full built-in header set (`X-Deviceid` / `X-App-Version` /
    /// `X-AUTH` / `X-USER-ID` / ...) is applied unchanged — `X-Deviceid`
    /// in particular is verified by the server on this surface and must
    /// be the account's real value — and the usual `uuid` body injection
    /// applies as for any other JSON POST.
    ///
    /// `absolute_path` is host-relative, not a URL; a value carrying a
    /// scheme is rejected rather than silently pasted onto the host.
    pub fn post_raw_json(
        &self,
        absolute_path: String,
        body_json: String,
    ) -> Result<String, PovoError> {
        if absolute_path.contains("://") {
            return Err(PovoError::InvalidArgument(format!(
                "expected a host-relative path, got a URL: {absolute_path}"
            )));
        }
        let path = if absolute_path.starts_with('/') {
            absolute_path
        } else {
            format!("/{absolute_path}")
        };
        let body: serde_json::Value = serde_json::from_str(&body_json)?;
        let value = self.call_path("POST", true, &path, &path, Body::Json(body), None)?;
        Ok(value.to_string())
    }

    /// Generic JSON `POST` for endpoints not yet given a typed method above.
    pub fn post_json(
        &self,
        relative_path: String,
        prefix: Option<String>,
        version: String,
        locale: String,
        body_json: String,
    ) -> Result<String, PovoError> {
        let body: serde_json::Value = serde_json::from_str(&body_json)?;
        let value = self.call_route(
            "POST",
            true,
            ServiceRoute {
                prefix: prefix.as_deref(),
                version: &version,
                locale: &locale,
                relative_path: &relative_path,
            },
            Body::Json(body),
            None,
        )?;
        Ok(value.to_string())
    }

    /// Generic JSON request for endpoints using PUT, PATCH, or DELETE (and
    /// also POST/GET when a single integration surface is preferable).
    /// The method is restricted to standard HTTP verbs and all calls require
    /// an authenticated session.
    pub fn request_json(
        &self,
        method: String,
        relative_path: String,
        prefix: Option<String>,
        version: String,
        locale: String,
        body_json: Option<String>,
    ) -> Result<String, PovoError> {
        let method = method.to_ascii_uppercase();
        if !matches!(method.as_str(), "GET" | "POST" | "PUT" | "PATCH" | "DELETE") {
            return Err(PovoError::InvalidArgument(format!(
                "unsupported HTTP method: {method}"
            )));
        }
        let body = match body_json {
            Some(text) => Body::Json(serde_json::from_str(&text)?),
            None => Body::None,
        };
        let value = self.call_route(
            &method,
            true,
            ServiceRoute {
                prefix: prefix.as_deref(),
                version: &version,
                locale: &locale,
                relative_path: &relative_path,
            },
            body,
            None,
        )?;
        Ok(value.to_string())
    }

    /// Generic `application/x-www-form-urlencoded` `POST`, used by several
    /// legacy account endpoints (e.g. topup/addon purchase, roaming cap).
    pub fn post_form(
        &self,
        relative_path: String,
        prefix: Option<String>,
        version: String,
        locale: String,
        form: HashMap<String, String>,
    ) -> Result<String, PovoError> {
        let value = self.call_route(
            "POST",
            true,
            ServiceRoute {
                prefix: prefix.as_deref(),
                version: &version,
                locale: &locale,
                relative_path: &relative_path,
            },
            Body::Form(form),
            None,
        )?;
        Ok(value.to_string())
    }
}

/// `{"token": "...", "version": "v2", "action": "LOGIN"}` base64-encoded,
/// matching `Captcha.kt` (`p134g4/b.java`) exactly.
fn captcha_b64(token: &str) -> String {
    let payload = json!({ "token": token, "version": "v2", "action": "LOGIN" });
    base64::engine::general_purpose::STANDARD.encode(payload.to_string())
}

/// Matches `UniversalUrlGenerator.kt`: a JSON POST body gets a `uuid` field
/// injected if it doesn't already have one.
fn inject_uuid_json(body: &mut serde_json::Value) {
    if let serde_json::Value::Object(map) = body {
        map.entry("uuid").or_insert_with(|| json!(random_request_uuid()));
    }
}

/// The `layout/bills/info` sections that hold entry lists, in the order
/// `get_bills_info` returns them.
const BILL_SECTIONS: [&str; 3] = ["past_bills", "upcoming_bill", "instant_charges"];

/// Flatten the `layout/bills/info` payload; see `PovoClient::get_bills_info`
/// for the response shape this is built against.
fn parse_bills_info(value: &serde_json::Value) -> Vec<BillEntry> {
    let mut entries = Vec::new();
    for section in BILL_SECTIONS {
        let Some(list) = value
            .get(section)
            .and_then(|s| s.get("list"))
            .and_then(|v| v.as_array())
        else {
            continue;
        };
        entries.extend(list.iter().map(|entry| BillEntry {
            section: section.to_string(),
            bill_id: entry
                .get("billId")
                .or_else(|| entry.get("bill_id"))
                .and_then(|v| v.as_str())
                .map(str::to_string),
            label: entry.get("label").and_then(|v| v.as_str()).map(str::to_string),
            raw_json: entry.to_string(),
        }));
    }
    entries
}

/// The Android Retrofit stack has both wrapped and bare response producers in
/// different client configurations. Accept both without changing the raw
/// JSON escape-hatch methods.
fn unwrap_result(value: serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => map
            .get("result")
            .cloned()
            .unwrap_or(serde_json::Value::Object(map)),
        other => other,
    }
}

impl PovoClient {
    fn send_otp(&self, req: OtpSendRequest) -> Result<OtpSendResponse, PovoError> {
        let body = serde_json::to_value(&req)?;
        let value = self.call_user_service("POST", false, "otp", Body::Json(body), None)?;
        Ok(serde_json::from_value(unwrap_result(value))?)
    }

    fn agent_request(&self, method: &str, url: &str) -> ureq::Request {
        let state = self.state.lock().unwrap();
        let user_id = state
            .auth_token
            .as_deref()
            // CredentialsPreferences.getUserId() in the APK calls
            // JWT.c(), which reads the payload's `external_id` claim. The
            // `iss` claim is separately validated as "circles" and is not
            // the value sent in X-USER-ID.
            .and_then(|t| jwt::claim(t, "external_id"))
            .unwrap_or_default();
        // No `Accept`/`Accept-Language` here: searched the full decompiled
        // interceptor chain (`DeviceInfoInterceptor`, `TimeZoneInterceptor`,
        // `VersionLocaleInterceptor`, `UniversalUrlGenerator`,
        // `ProactiveSessionManager`) and neither header is ever set by the
        // real app — locale is carried in the URL path (`/jp/ja/`)
        // instead, and no `Accept` is sent at all. Every header below is
        // confirmed present in one of those interceptors.
        let mut req = state
            .agent
            .request(method, url)
            .set("X-Deviceid", &state.device_id)
            .set("X-App-Version", &state.app_version)
            .set("X-App-Platform", "Android")
            .set("X-Timezone", "Asia/Tokyo")
            .set("X-REQUEST-ID", &random_request_id())
            .set("X-USER-ID", &user_id)
            .set("User-Agent", &state.user_agent)
            // The Android interceptor writes this header even before login;
            // preserve the header shape with an empty value when no token
            // has been established yet.
            .set("X-AUTH", state.auth_token.as_deref().unwrap_or(""));
        if url.contains("user-service") {
            req = req.set("Feature-Type", "t2");
        }
        if state.user_type.as_deref() == Some("Guest") {
            req = req.set("X-Enable-Auth", "true");
        }
        // Last, so a caller-supplied header overrides a built-in one.
        for (name, value) in &state.extra_headers {
            req = req.set(name, value);
        }
        req
    }

    /// Central request path for the plain account-service host (no
    /// user-service prefix): applies the `sin`/`uuid` behavior recovered
    /// from `UniversalUrlGenerator.kt` (`p415u5/i.java`) — `sin` and `uuid`
    /// as query params on `GET`, `uuid` injected into the body on `POST`;
    /// both skipped for `quilt` paths, matching the decompiled client.
    fn call_account(
        &self,
        method: &str,
        version: &str,
        locale: &str,
        relative_path: &str,
        body: Body,
    ) -> Result<serde_json::Value, PovoError> {
        self.call_route(
            method,
            true,
            ServiceRoute {
                prefix: None,
                version,
                locale,
                relative_path,
            },
            body,
            None,
        )
    }

    fn call_user_service(
        &self,
        method: &str,
        auth_required: bool,
        relative_path: &str,
        body: Body,
        captcha_token: Option<String>,
    ) -> Result<serde_json::Value, PovoError> {
        self.call_user_service_with(
            method,
            auth_required,
            ServiceRoute {
                prefix: Some(USER_SERVICE_PREFIX),
                version: "v4",
                locale: "ja",
                relative_path,
            },
            body,
            captcha_token,
        )
    }

    fn call_user_service_with(
        &self,
        method: &str,
        auth_required: bool,
        route: ServiceRoute<'_>,
        body: Body,
        captcha_token: Option<String>,
    ) -> Result<serde_json::Value, PovoError> {
        if auth_required && self.auth_token().is_none() {
            return Err(PovoError::Unauthenticated);
        }
        self.call_route(method, false, route, body, captcha_token)
    }

    fn call_route(
        &self,
        method: &str,
        auth_required: bool,
        route: ServiceRoute<'_>,
        body: Body,
        captcha_token: Option<String>,
    ) -> Result<serde_json::Value, PovoError> {
        let path = build_path(
            route.prefix,
            route.version,
            route.locale,
            route.relative_path,
        );
        self.call_path(
            method,
            auth_required,
            &path,
            route.relative_path,
            body,
            captcha_token,
        )
    }

    /// Shared request tail. `path` is the final host-relative path;
    /// `route_path` is what the `sin`/`uuid` decoration rules are matched
    /// against — the same string for a raw path, and the un-prefixed
    /// relative path for a route built by `build_path` (so that e.g.
    /// `quilt/` is still recognized once the version/locale segments are in
    /// front of it).
    fn call_path(
        &self,
        method: &str,
        auth_required: bool,
        path: &str,
        route_path: &str,
        body: Body,
        captcha_token: Option<String>,
    ) -> Result<serde_json::Value, PovoError> {
        if auth_required && self.auth_token().is_none() {
            return Err(PovoError::Unauthenticated);
        }
        let url = self.decorate_url(method, &format!("{HOST_APP}{path}"), route_path);
        if let Some(token) = captcha_token {
            let req = self.agent_request(method, &url).set("X-Captcha", &captcha_b64(&token));
            return self.send_with(req, body);
        }
        self.send(method, &url, body)
    }

    fn decorate_url(&self, method: &str, base_url: &str, route_path: &str) -> String {
        if !method.eq_ignore_ascii_case("GET") {
            return base_url.to_string();
        }

        // UniversalUrlGenerator only adds uuid/sin once a service instance
        // number is known. It skips notification polling, Quilt pages, and
        // auth0 session-token URLs.
        let is_quilt = route_path.contains("/quilt") || route_path.starts_with("quilt/");
        let is_notification = route_path.contains("notification/history/push");
        let is_auth0 = route_path.contains("auth0/session/token");
        if is_quilt || is_notification {
            return base_url.to_string();
        }
        let sin = self.state.lock().unwrap().sin.clone();
        let Some(sin) = sin else {
            return base_url.to_string();
        };

        let mut url = base_url.to_string();
        if !is_auth0 && !url.contains("uuid=") {
            url = append_query(url, "uuid", &random_request_uuid());
        }
        if !url.contains("sin=") {
            url = append_query(url, "sin", &sin);
        }
        url
    }

    fn send(&self, method: &str, url: &str, body: Body) -> Result<serde_json::Value, PovoError> {
        let req = self.agent_request(method, url);
        self.send_with(req, body)
    }

    fn send_with(&self, req: ureq::Request, body: Body) -> Result<serde_json::Value, PovoError> {
        let response = match body {
            Body::None => req.call()?,
            Body::Json(mut json_body) => {
                inject_uuid_json(&mut json_body);
                req.send_json(json_body)?
            }
            Body::Form(mut form) => {
                form.entry("uuid".to_string()).or_insert_with(random_request_uuid);
                let pairs: Vec<(&str, &str)> = form.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
                req.set("Content-Type", "application/x-www-form-urlencoded")
                    .send_form(&pairs)?
            }
        };
        let text = response.into_string()?;
        if text.trim().is_empty() {
            Ok(serde_json::Value::Null)
        } else {
            Ok(serde_json::from_str(&text)?)
        }
    }

    fn get_v4_json(&self, relative_path: &str) -> Result<String, PovoError> {
        Ok(self.call_account("GET", "v4", "ja", relative_path, Body::None)?.to_string())
    }

    /// Matches `DeviceMeta`'s real defaults (`DeviceMeta.kt`): every
    /// instance the Android app constructs sets `device_type: "Mobile"`,
    /// `app_type: "ecosystem"`; `token_type` defaults to `"FCM"` but is only
    /// meaningful together with a real push `device_token`, which this
    /// library has no way to obtain (no FCM/APNs registration), so it's
    /// left unset here rather than sent with no matching token.
    fn default_device_meta(&self) -> serde_json::Value {
        json!({
            "device_id": self.device_id(),
            "device_type": "Mobile",
            "app_type": "ecosystem",
        })
    }
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn append_query(mut url: String, key: &str, value: &str) -> String {
    let separator = if url.contains('?') { '&' } else { '?' };
    url.push(separator);
    url.push_str(&urlencode(key));
    url.push('=');
    url.push_str(&urlencode(value));
    url
}

fn build_quilt_page_path(page: &str, query: Option<&HashMap<String, String>>) -> String {
    let (page_name, inline_query) = match page.split_once('?') {
        Some((p, q)) => (p, Some(q)),
        None => (page, None),
    };
    let mut url = format!("/api/v1/quilt/page/{}", urlencode(page_name.trim_start_matches('/')));
    if let Some(q) = inline_query {
        for pair in q.split('&').filter(|s| !s.is_empty()) {
            match pair.split_once('=') {
                Some((k, v)) => url = append_query(url, k, v),
                None => url = append_query(url, pair, ""),
            }
        }
    }
    if let Some(map) = query {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        for k in keys {
            if let Some(v) = map.get(k) {
                url = append_query(url, k, v);
            }
        }
    }
    url
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Values here are placeholders, never real account data.
    fn client() -> Arc<PovoClient> {
        PovoClient::new("device-under-test".to_string(), "0.0.0".to_string())
    }

    #[test]
    fn parses_every_bills_info_section() {
        let payload = json!({
            "past_bills": { "list": [
                { "billId": "b1", "label": "past" },
                { "bill_id": "b2" },
            ]},
            "upcoming_bill": { "list": [{ "label": "upcoming" }] },
            "instant_charges": { "list": [{ "label": "instant" }] },
            "banner": { "list": [{ "label": "not a bill" }] },
        });
        let entries = parse_bills_info(&payload);
        let seen: Vec<(&str, Option<&str>)> = entries
            .iter()
            .map(|e| (e.section.as_str(), e.bill_id.as_deref()))
            .collect();
        assert_eq!(
            seen,
            vec![
                ("past_bills", Some("b1")),
                ("past_bills", Some("b2")),
                ("upcoming_bill", None),
                ("instant_charges", None),
            ]
        );
        assert!(entries[0].raw_json.contains("\"billId\""));
    }

    #[test]
    fn ignores_bills_info_shapes_that_do_not_exist() {
        // The top-level `bills`/`result` array an earlier version of
        // get_bills_info looked for is not in the real response.
        assert!(parse_bills_info(&json!({ "bills": ["b1"] })).is_empty());
        assert!(parse_bills_info(&json!({ "result": ["b1"] })).is_empty());
        assert!(parse_bills_info(&json!({ "past_bills": {} })).is_empty());
    }

    #[test]
    fn get_raw_json_rejects_a_url() {
        let error = client()
            .get_raw_json("https://example.invalid/api/v1/quilt/page/x".to_string())
            .unwrap_err();
        assert!(matches!(error, PovoError::InvalidArgument(_)), "{error:?}");
    }

    #[test]
    fn get_raw_json_requires_a_token() {
        let error = client()
            .get_raw_json("/api/v1/quilt/page/order-history".to_string())
            .unwrap_err();
        assert!(matches!(error, PovoError::Unauthenticated), "{error:?}");
    }

    #[test]
    fn quilt_paths_are_not_decorated() {
        let client = client();
        client.set_service_instance_number(Some("sin-under-test".to_string()));
        let quilt = "/api/v1/quilt/page/user-plan-details-v2";
        assert_eq!(
            client.decorate_url("GET", &format!("{HOST_APP}{quilt}"), quilt),
            format!("{HOST_APP}{quilt}")
        );
    }

    #[test]
    fn account_gets_are_decorated_with_sin_and_uuid() {
        let client = client();
        client.set_service_instance_number(Some("sin/under test".to_string()));
        let url = client.decorate_url(
            "GET",
            &format!("{HOST_APP}/v4/jp/ja/mobile/account/usage/plan/get"),
            "account/usage/plan/get",
        );
        assert!(url.contains("uuid="), "{url}");
        assert!(url.contains("sin=sin%2Funder%20test"), "{url}");
    }

    #[test]
    fn post_raw_json_rejects_a_url() {
        let error = client()
            .post_raw_json(
                "https://example.invalid/v4/jp/ja/webfront/users/session".to_string(),
                "{}".to_string(),
            )
            .unwrap_err();
        assert!(matches!(error, PovoError::InvalidArgument(_)), "{error:?}");
    }

    #[test]
    fn post_raw_json_requires_a_token() {
        let error = client()
            .post_raw_json(
                "/api/v3/user-service/v4/jp/ja/webfront/users/session".to_string(),
                "{}".to_string(),
            )
            .unwrap_err();
        assert!(matches!(error, PovoError::Unauthenticated), "{error:?}");
    }

    #[test]
    fn get_quilt_page_json_requires_a_token() {
        let error = client()
            .get_quilt_page_json("profile".to_string())
            .unwrap_err();
        assert!(matches!(error, PovoError::Unauthenticated), "{error:?}");
    }

    #[test]
    fn profile_parses_telco_activation_dates() {
        let payload = json!({
            "telco_info": {
                "service_instance_no": "sin",
                "activation_date": "2024-01-01T00:00:00.000Z",
                "initial_activation_date": "2023-05-04T00:00:00.000Z",
            }
        });
        let profile = UserProfile::from_json(&payload);
        let telco = profile.telco_info.unwrap();
        assert_eq!(telco.activation_date.as_deref(), Some("2024-01-01T00:00:00.000Z"));
        assert_eq!(
            telco.initial_activation_date.as_deref(),
            Some("2023-05-04T00:00:00.000Z")
        );
    }

    #[test]
    fn expires_at_reads_the_token_exp() {
        let client = client();
        assert_eq!(client.expires_at(), None);
        // `e30` is the base64url of `{}`; the payload is the only segment
        // this reads, and the fixture is deliberately unsigned.
        let payload =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"exp":1893456000}"#);
        client.set_auth_token(format!("e30.{payload}."));
        assert_eq!(client.expires_at(), Some(1893456000));
    }

    #[test]
    fn expires_at_falls_back_to_expiry_time() {
        let client = client();
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(br#"{"expiry_time":"1893456000"}"#);
        client.set_auth_token(format!("e30.{payload}."));
        assert_eq!(client.expires_at(), Some(1893456000));
    }

    #[test]
    fn quilt_page_path_preserves_inline_and_map_queries() {
        assert_eq!(
            build_quilt_page_path("usage-history?type=DAILY", None),
            "/api/v1/quilt/page/usage-history?type=DAILY"
        );
        let mut query = HashMap::new();
        query.insert("type".to_string(), "MONTHLY".to_string());
        assert_eq!(
            build_quilt_page_path("usage-history", Some(&query)),
            "/api/v1/quilt/page/usage-history?type=MONTHLY"
        );
    }

    #[test]
    fn place_topping_order_requires_a_token() {
        let error = client()
            .place_topping_order("sku-1".to_string(), Some("https://povo.jp/success".to_string()))
            .unwrap_err();
        assert!(matches!(error, PovoError::Unauthenticated), "{error:?}");
    }
}
