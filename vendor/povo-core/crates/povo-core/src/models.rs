use serde::{Deserialize, Serialize};

/// Device identity sent with most account-service calls.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct DeviceMeta {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_id: Option<String>,
    pub device_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub advertisement_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ActionType {
    #[serde(rename = "LOGIN_OTP")]
    LoginOtp,
    #[serde(rename = "EMAIL_OTP")]
    EmailOtp,
    #[serde(rename = "REGISTER_OTP")]
    RegisterOtp,
}

#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct LoginActionMetadata {
    pub message: Option<String>,
}

#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct LoginAction {
    #[serde(rename = "action")]
    pub action_type: ActionType,
    pub metadata: Option<LoginActionMetadata>,
}

/// Response of `POST users/login/action`: tells the client which
/// verification steps (in order) are required before `users/auth` will
/// accept a login for this identifier.
#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct LoginActionsResponse {
    #[serde(default)]
    pub actions: Vec<LoginAction>,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, uniffi::Enum)]
pub enum AuthMode {
    #[serde(rename = "ENHANCED_EMAIL_OTP")]
    EnhancedEmailOtp,
    #[serde(rename = "ENHANCED_SMS")]
    EnhancedSms,
    #[serde(rename = "EMAIL")]
    Email,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, uniffi::Enum)]
pub enum RequestType {
    #[serde(rename = "LOGIN_EMAIL_OTP")]
    LoginEmailOtp,
    #[serde(rename = "LOGIN_MOBILE_OTP")]
    LoginMobileOtp,
    #[serde(rename = "VERIFY_EMAIL_OTP")]
    VerifyEmailOtp,
    #[serde(rename = "REGISTER_WITH_OTP")]
    RegisterWithOtp,
}

#[derive(Debug, Clone, Serialize)]
pub struct OtpSendRequest {
    pub device_id: String,
    pub otp_duration: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phone_no: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub isd_code: Option<String>,
    /// The APK sets this only on the statically identified
    /// `VERIFY_EMAIL_OTP` constructor path; ordinary login OTP requests
    /// leave it null and Gson omits it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
    pub auth_mode: AuthMode,
    pub request_type: RequestType,
}

#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct OtpSendResponse {
    pub auth_id: String,
    pub device_id: Option<String>,
}

/// The "email_auth" / "mobile_auth" challenge-response sent back with the
/// OTP code the user typed in, referencing the `auth_id` issued by
/// `send_email_otp` / `send_mobile_otp`.
#[derive(Debug, Clone, Serialize, uniffi::Record)]
pub struct AuthChallenge {
    pub auth_id: String,
    pub otp_code: String,
    pub device_id: String,
}

#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct TokenResponse {
    pub auth_token: String,
    #[serde(default)]
    pub first_login: bool,
    /// Present on some app builds as a step-up-auth (PIN) challenge token.
    /// Found only via static analysis (v1.70.0 `UserService.pin/validate`);
    /// not observed on real traffic by prior field research. Treat as
    /// optional: if absent, `auth_token` is already usable.
    #[serde(default)]
    pub pin_token: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UserProfileDob {
    pub year: Option<i32>,
    pub month: Option<i32>,
    pub day: Option<i32>,
    pub timestamp: Option<i64>,
}

/// `circles_info` inside `telco_info`. Field names confirmed via
/// `@SerializedName` on the APK's `BillingInfo` model (static analysis;
/// Gson field-name annotations survive R8 obfuscation intact).
#[derive(Debug, Clone, uniffi::Record)]
pub struct BillingInfo {
    pub billing_account_number: Option<String>,
    pub billing_cycle_name: Option<String>,
    pub customer_account: Option<String>,
    pub customer_ported: bool,
    pub customer_ported_status: Option<String>,
    pub order_reference_number: Option<String>,
    pub referral_code: Option<String>,
    /// `service_instance_base_plan_name` — the line's plan name.
    pub plan_name: Option<String>,
}

/// Confirmed via `@SerializedName` on the APK's `TelcoInfo` model (static
/// analysis). `service_instance_no` ("SIN") is the key field: the running
/// Android client caches it after every profile fetch and silently adds it
/// as a `sin` query parameter to subsequent `GET` calls (see
/// `UniversalUrlGenerator.kt` / `p415u5/i.java`) — that's how multi-line
/// accounts scope requests to one phone line. [`PovoClient`] replicates
/// this: see `PovoClient::service_instance_number`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TelcoInfo {
    pub service_instance_no: Option<String>,
    pub service_account_email: Option<String>,
    pub customer_name: Option<String>,
    pub isd_code: Option<String>,
    pub phone_no: Option<String>,
    pub status: Option<String>,
    /// The current line's activation date, ISO-8601
    /// (`2024-01-01T00:00:00.000Z`). The value is UTC midnight, so
    /// converting to JST shifts it one day forward — take the date part
    /// (`YYYY-MM-DD`) as-is and drop the time instead.
    pub activation_date: Option<String>,
    /// The account's first-ever activation date; equal to
    /// `activation_date` unless the line was reissued. Useful as a
    /// fallback when `activation_date` is absent.
    pub initial_activation_date: Option<String>,
    pub billing_info: Option<BillingInfo>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UserProfile {
    pub external_id: Option<String>,
    pub first_name: Option<String>,
    pub email: Option<String>,
    pub user_type: Option<String>,
    pub dob: Option<UserProfileDob>,
    pub telco_info: Option<TelcoInfo>,
}

impl UserProfile {
    /// `GET users?include_telco=true` has been observed both as a bare
    /// object and wrapped as `{ "result": { ... } }`; unwrap defensively.
    pub(crate) fn from_json(value: &serde_json::Value) -> Self {
        let obj = value.get("result").unwrap_or(value);
        let s = |o: &serde_json::Value, k: &str| o.get(k).and_then(|v| v.as_str()).map(str::to_string);
        let dob = obj.get("dob").map(|d| UserProfileDob {
            year: d.get("year").and_then(|v| v.as_i64()).map(|v| v as i32),
            month: d.get("month").and_then(|v| v.as_i64()).map(|v| v as i32),
            day: d.get("day").and_then(|v| v.as_i64()).map(|v| v as i32),
            timestamp: d.get("timestamp").and_then(|v| v.as_i64()),
        });
        let telco_info = obj.get("telco_info").map(|t| TelcoInfo {
            service_instance_no: s(t, "service_instance_no"),
            service_account_email: s(t, "service_account_email"),
            customer_name: s(t, "customer_name"),
            isd_code: s(t, "isd_code"),
            phone_no: s(t, "phone_no"),
            status: s(t, "status"),
            activation_date: s(t, "activation_date"),
            initial_activation_date: s(t, "initial_activation_date"),
            billing_info: t.get("circles_info").map(|b| BillingInfo {
                billing_account_number: s(b, "billing_account_number"),
                billing_cycle_name: s(b, "billing_cycle_name"),
                customer_account: s(b, "customer_account"),
                customer_ported: b.get("customer_ported").and_then(|v| v.as_bool()).unwrap_or(false),
                customer_ported_status: s(b, "customer_ported_status"),
                order_reference_number: s(b, "order_reference_number"),
                referral_code: s(b, "referral_code"),
                plan_name: s(b, "service_instance_base_plan_name"),
            }),
        });
        UserProfile {
            external_id: s(obj, "external_id"),
            first_name: s(obj, "first_name"),
            email: s(obj, "email"),
            user_type: s(obj, "user_type"),
            dob,
            telco_info,
        }
    }
}

/// One entry from the `layout/bills/info` timeline. See
/// `PovoClient::get_bills_info` for how the payload is flattened.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BillEntry {
    /// Which timeline section the entry came from: `past_bills`,
    /// `upcoming_bill`, or `instant_charges`.
    pub section: String,
    /// The `billId` to hand to `PovoClient::download_bill_pdf`. Only past
    /// bills have one — there is no PDF for an upcoming bill or an instant
    /// charge, so this is `None` for those sections.
    pub bill_id: Option<String>,
    pub label: Option<String>,
    pub raw_json: String,
}

/// Response of `POST /v2/jp/ja/mobile/shop/orders`
/// (`PurchaseBoostResponse$Result` in the APK).
///
/// A `200 OK` does **not** mean a completed purchase when `challenge_url` is
/// present: the order is pending 3-D Secure authentication at `challenge_url`,
/// and nothing is charged until that challenge completes and redirects to
/// `redirect_url`.
#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct ToppingOrderResult {
    #[serde(default)]
    pub challenge_url: Option<String>,
    #[serde(default)]
    pub order_ref: Option<String>,
    #[serde(default)]
    pub order_id: Option<String>,
    #[serde(default)]
    pub p_ref: Option<String>,
}
