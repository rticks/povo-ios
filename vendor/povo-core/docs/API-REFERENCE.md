# povo-core API reference

This document belongs to this project. It describes the stable request contract
recovered from the `com.kddi.kdla.jp` 1.70.0-JP APK and checked on an authorized
Android emulator and account. It contains no account values, tokens, OTPs, SINs,
or session identifiers.

## Hosts and URL construction

Production host: `https://app.povo.jp`.

Most User Service routes use:

```text
{prefix}/{version}/jp/{locale}/mobile/{relative_path}
```

The verified login routes are:

| Operation | Final path |
|---|---|
| login action | `/api/v3/user-service/v4/jp/ja/mobile/users/login/action` |
| send OTP | `/api/v3/user-service/v4/jp/ja/mobile/otp` |
| complete login | `/user-service/v5/public/jp/ja/mobile/users/auth` |
| profile | `/api/v3/user-service/v4/jp/ja/mobile/users?include_telco=true` |
| device registration | `/api/v3/user-service/v4/jp/ja/mobile/users/devices` |

Account routes normally use `/v4/jp/ja/mobile/...`; the typed billing timeline
uses `/v5/jp/ja/mobile/layout/bills/info`. `telco/settings` uses locale `en`.

### Non-localized routes

Quilt pages are **not** localized and sit at their own absolute paths:

```text
/api/v1/quilt/page/{page}
```

The formula above cannot produce such a path, so these routes are unreachable
through the localized methods and answer `404` if attempted. `get_raw_json`
exists for them; it sends the path as given while still applying the normal
headers, authentication, and GET decoration rules. `get_quilt_page_json(page)`
is the typed convenience wrapper for this fixed route.

Quilt page names confirmed in use:

| Page | Contents |
|---|---|
| `dashboard-v2` | purchasable topping catalog (`addon-section` tiles: `items[].data` + `items[].action.data.product_popup` with `id`, `title`, `price`, `is_3ds_topping`) |
| `user-plan-details-v2` | currently subscribed toppings — the **only** working source |
| `order-history` | purchase history — the **only** working source |
| `profile` | payment method (`tile-credit-card` tile: masked card number plus the `shop.povo.jp` change URL), name, address, masked PIN |
| `usage-history` | data-usage graph page reached from the dashboard usage card. Takes a `type` query param: `DAILY` (default) or `MONTHLY`; the app re-fetches with the new `type` when the user toggles. The graph arrives as a server-driven `povo-tile-graph` tile: `data.title` plus `data.graph_details[]` = `{usage: Float, time: String, tooltip: {title, subtitle}}` — values are display-ready, the app applies no unit conversion |

The `profile` page is notable: it does not appear in the APK-derived endpoint
list at all and is known only from the running app. Other quilt page names
found in the APK's navigation map (`B7/j.java`) include `plan-usage`,
`usage-logs`, `data-rollover`, `2020-rollover`, `dream-plan-details-v3`,
`secondary-sim-home`, `family-plan-summary`, `5g-dashboard` — presence in the
map means the app can render the page, not that the page exists on the server.

## Authentication

1. `POST users/login/action` with an email or phone identifier. The email flow
   sends an `X-Captcha` header when the host supplies a CAPTCHA token. The body
   omits null fields; the observed email request contains only `email` before
   the common JSON `uuid` is added. The tested account needed no CAPTCHA.
2. `POST otp` with `auth_mode`, `request_type`, `device_id`, `otp_duration`,
   and the destination field.
3. `POST users/auth` with `device` and the completed `email_auth` and/or
   `mobile_auth` challenge.
4. Store the returned `auth_token` in platform-secure storage. A `pin_token`
   may indicate a server-side step-up flow; it was not observed in the tested
   email login.

The APK derives `X-USER-ID` from the JWT `external_id` claim. The `iss` claim
is the tenant value `circles` and is not the user ID.

Tokens carry a numeric `exp` claim and last exactly 1200 seconds. `GET
users/token` refreshes an expired token successfully, but returns the *same*
JWT when called before expiry — so schedule refreshes off `expires_at()`
rather than treating a successful call as proof of a new token.

## Common request behavior

The Android client adds, as applicable:

```text
X-Deviceid, X-App-Version, X-App-Platform: Android, X-Timezone,
X-REQUEST-ID, X-USER-ID, X-AUTH, User-Agent
```

User Service requests also receive `Feature-Type: t2`. JSON and form POSTs get a
signed 64-bit request `uuid`; GETs receive `uuid` and `sin` after a service
instance number has been learned from the profile. Quilt and notification
polling routes are exceptions to the GET decoration rules.

This core builds its own paths, so it sends no `VLI-*` headers, and the
decompiled interceptor chain sets no `Accept`/`Accept-Language` either.
`set_extra_header` allows a host to test that assumption per endpoint. Sending
povo-native's full set (`Accept`, `Accept-Language`, `VLI-Version`,
`VLI-Localize`) did not change `telco/dashboard`'s `HTTP 500`, so no extra
header is needed for any endpoint covered here.

## Error bodies

Error payloads arrive in more than one shape (`ThrowableUtils.kt` /
`com.circles.api.retrofit.exception.a`). The fields may be at the top level or
nested under `"error"`, `"result"`, `"failure"`, or `"response"`:

- a real `401` is `{"success": false, "result": {"message": "Token Expired"}}`
- a `422` from subscription/order validation is
  `{"success": false, "result": null, "failure": {"code": 4221131, "title": "ERROR_SUBSCRIPTION_BUSINESS_VALIDATION_FAILED", "description": "[checkActivateEligibility]: No subscription to activate for the request"}}`

All of these are unwrapped into `PovoError::Api`, with `server_message`
resolving `message`, `description`, `ErrInfo`, `error`, or `title` in order.
The server's text is exposed as `server_message`, not `message`: uniffi's
Kotlin backend generates an `override val message` on every error class, and a
variant field of that name collides with it.

## Rust surface

`PovoClient` provides typed methods for login, OTP, profile, token refresh,
device registration, usage, billing, referral, settings, bill PDF decoding, and
topping purchase (`place_topping_order`). The generic methods accept a route
prefix explicitly:

```text
get_json(relative_path, prefix, version, locale)
post_json(relative_path, prefix, version, locale, json)
post_form(relative_path, prefix, version, locale, form)
request_json(method, relative_path, prefix, version, locale, optional_json)
get_raw_json(absolute_path)
post_raw_json(absolute_path, json)
get_quilt_page_json(page)
get_quilt_page_with_query_json(page, query)
```

Use `Some("/api/v3/user-service")` or `Some("/user-service")` for User Service
routes and `None` for account routes. All generic account calls require an
authentication token. `get_raw_json` / `post_raw_json` take a host-relative
path verbatim and are the only way to reach a non-localized route; they reject
a full URL. `post_raw_json` exists because the web-front surface (`webfront/*`)
carries no `mobile` segment and has POST-only routes, so neither the localized
methods nor `get_raw_json` can reach it. The full header set (`X-Deviceid`
included) and the JSON `uuid` injection apply exactly as for any other call.

Variable account/usage and Quilt response payloads intentionally remain raw
JSON. Their shape depends on the account, plan, and server-side configuration.

Other host-facing helpers: `expires_at()` for the token deadline, and
`set_extra_header(name, value)` to append or override a request header.

## Endpoint status

Checked against a real account. Included because several endpoints that static
analysis suggested do not work, and the working alternative is not obvious.

| Endpoint | Result |
|---|---|
| `POST users/login/action`, `otp`, `users/auth` | OK — no CAPTCHA or PIN required |
| `GET users/token` | OK — refreshable after expiry; lifetime exactly 1200 s |
| `GET users?include_telco=true` | OK |
| `GET account/usage/plan/get` | OK — values are decimals, in KB, base 1024 |
| `GET layout/bills/info` | OK — see the billing note below |
| `GET billing/bills/download/{billId}` | OK — PDF password is `YYYY-MM-DD` |
| `GET account/referral/code/get` | OK |
| `GET /api/v1/quilt/page/user-plan-details-v2` | OK — **only** source of subscribed toppings |
| `GET /api/v1/quilt/page/order-history` | OK — **only** source of purchase history |
| `GET account/plan/details/get` | `HTTP 500 error_db_transaction` |
| `GET account/usage/data/details/get` | `HTTP 491 error_not_found_message` |
| `GET account/addon/topup/all/get` | `HTTP 500 error_system_issue` |
| `POST telco/dashboard` | `HTTP 500 error_code_common` (all cards, and boost-only) |
| `GET telco/dashboard` | `HTTP 404` — POST only |

### Subscribed toppings

`account/usage/plan/get` has no `addons_subscribed` field despite what static
analysis suggested, and both typed alternatives return `HTTP 500`. The
`user-plan-details-v2` Quilt page is the only working source; reach it with
`get_raw_json`.

### Topping purchase

The purchasable catalog lives on `/api/v1/quilt/page/dashboard-v2` under
`addon-section` tiles (`items[].data` for row display and
`items[].action.data.product_popup` for the `id` SKU, full `title`, formatted
`price`, and `is_3ds_topping` flag).

One-off topping orders (`ProductPopupBottomSheetDialog.kt` / `F8/q.java` →
`ShopApi.kt` / `X9/d.java` method `c` with `BuyEntertainerRequest`) use **`v2`**
and `PovoClient::place_topping_order(sku, redirect_url)`:

```text
POST /v2/jp/ja/mobile/shop/orders     (VLI-Version: v2)
{ "sku": "<product_popup.id>", "offer_product": null, "redirect_url": "https://povo.jp/success" }
→ { "success": true,
    "result": { "challenge_url": "https://front.secure.gmopg.jp/auth/brw/callback?...",
                "order_ref": "...", "p_ref": "..." } }
```

When `challenge_url` is present, the order is pending 3-D Secure authentication
and nothing has been charged yet; when absent, the purchase is already complete.

By contrast, `POST /v1/jp/ja/mobile/subscription/activate` (and
`PUT /v1/jp/ja/mobile/subscription/cancel`, `A3/a.java`) is for monthly partner
subscriptions and returns `HTTP 422 ERROR_SUBSCRIPTION_BUSINESS_VALIDATION_FAILED`
for one-off toppings:

```text
POST /v1/jp/ja/mobile/subscription/activate     (VLI-Version: v1)
{ "customerId": "<X-USER-ID>", "accountId": "<SIN>",
  "subscriptions": [ { "productId": "<id>" } ] }
```

Other purchase surfaces present in the APK:

| Route | Body | Notes |
|---|---|---|
| `POST /v2/jp/ja/mobile/shop/orders` (AR variant) | JSON `{sku, auto_recharge, offer_product, redirect_url}` | auto-recharge topping purchase (`BuyArAddonRequest` / `k.java`) |
| `POST /v2/jp/ja/mobile/shop/3ds/callback` | JSON `{order_ref, p_ref}` | 3DS callback (`Shop3dsCallbackRequest` / `Z9/a.java`) |
| `GET /v2/jp/ja/mobile/shop/orders/{order_ref}` | — | 3DS order payment status (`OrderRef3dsResponse`) |
| `GET /v1/jp/ja/mobile/shop/orders/{order_ref}/payment_status` | — | payment status polling (`Y9/g.java`) |
| `POST /v4/jp/ja/mobile/billing/prepaid/subscription/buy` | JSON `{segmentation_id, billingAccountNumber, subscription_items: [{product_id, product_name}], subscription_amt}` | billing-side subscription purchase (`Y6/a.java`) |
| `POST /v4/jp/ja/mobile/account/topup/update/set` | form `id`, `action`, `payment`, `fromDate` (+ auto `uuid`) | legacy one-shot boost purchase; response carries `code`, `result`, `error`, optional `popup`, `order_ref`/`order_id`/`p_ref` |
| `POST /v4/jp/ja/mobile/account/general/update/set` | JSON `{id, action, uuid}` or form `id`/`action`/`request_meta` | generic addon update (`PurchaseAddonApiRequest`) |
| `POST /v4/jp/ja/mobile/account/addon/extra/update/batch/set` | JSON batch | extra addons |

Legacy catalog endpoints in the APK: `account/addon/topup/all/get`
(**measured `HTTP 500`**, see dead-routes), `account/addon/general/all/get`
(returns overseas roaming settings, not toppings), `account/addon/extra/all/get`
(empty arrays in practice), and the product master
`GET /v4/jp/ja/mobile/sphere/users/{userId}/products?id=<productIds>`.

### Billing timeline

`layout/bills/info` has no top-level `bills` or `result` array. Its top-level
keys are:

```text
au_services_status, banner, billing, code, instant_charges, past_bills, upcoming_bill
```

Bills are in `past_bills.list[]`. `get_bills_info()` returns the entries of
`past_bills`, `upcoming_bill`, and `instant_charges`, each tagged with its
`section`; only `past_bills` entries carry a `bill_id`.

The downloaded bill PDF is encrypted with the account holder's birth date
**including hyphens** (`YYYY-MM-DD`). The un-hyphenated form does not open it.

### Confirmed dead routes

Measured against a real account and recorded so nobody retries them. Note the
APK-derived endpoint list marks every payment route `x-verified: false` (only
11 of 215 listed routes have ever been confirmed against live traffic), and at
least these are actually unusable:

| Route | Observed |
|---|---|
| `GET /v4/jp/ja/mobile/layout/profile/info` | `HTTP 500 error_code_common` |
| `GET /v4/jp/en/mobile/layout/profile/info` | `HTTP 500 "Oops, operation failed."` |
| `GET /v4/jp/{ja,en}/mobile/profile/creditcard/update` | redirects to `api.wirecard.com.sg` → `NXDOMAIN`; Wirecard collapsed in 2020 and the domain no longer exists |
| `GET /v4/jp/ja/mobile/promotions/payment/url/get` | `HTTP 404 "no Route matched with those values"` |
| `GET /v4/jp/ja/mobile/telco/dashboard` | `HTTP 404` |
| `POST /v4/jp/ja/mobile/telco/dashboard` | `HTTP 500 error_code_common` (full body and boost-only alike) |

## Uncharted surface: `webfront/*` and checkout app settings

The `webfront` prefix does not appear in the APK-derived endpoint list at all;
it is known only from the `shop.povo.jp` SPA bundle. All of these live under
the user-service prefix **without** a `mobile` segment (confirmed for
`users/session`) and are POST-only, so they are reachable exclusively through
`post_raw_json`:

```text
POST /api/v3/user-service/v4/jp/ja/webfront/users/session
POST /api/v3/user-service/v4/jp/ja/webfront/users/session/update   (header: X-SessionID)
     /api/v3/user-service/v4/jp/ja/webfront/users/pin/reset/confirm
     /api/v3/user-service/v4/jp/ja/webfront/users/pin/change/confirm
     /api/v3/user-service/v4/jp/ja/webfront/users/pin/validate
```

Measured behavior of `users/session` (real account token and device id):

- Without the user-service prefix: `HTTP 404`.
- Without `X-Deviceid`: `HTTP 400 400101`; with a *random* `X-Deviceid`:
  `HTTP 403 403001`. Only the account's real device id passes authentication,
  after which the server validates the body: `session_id`, `journey` (string),
  `step` (integer), `action` are required, with distinct `40032`
  (`validate-Step` / `validate-Action` / `validate-Journey`) and `400001`
  (type error) failures for each.

However, the `step`/`action` values derive from the SPA's
`layout.page_session` configuration, whose bundled default covers only the
`/v2/*` onboarding funnel — so a created page session probably does not unlock
`/manage/payment-details`. The `/web/login` redirect more likely comes from a
plain missing web session (cookie). See the investigation report under
`research/` for the full WebView authentication analysis.

The SPA's own configuration endpoint is equally unlisted:

```text
GET /oms/checkout/app_settings
```

(bundle constants: `"/checkout/app_settings"` and `"/oms/checkout/app_settings"`).
It carries `layout.page_session`, `featureToggle`, `whitelist` and similar
settings that decide SPA behavior; whether `/manage/*` pages appear in its
`layout.page_session` determines whether the page-session theory holds.

## Boundaries

The APK cannot statically determine CAPTCHA remote configuration, account-state
challenge sequences, PIN requirements, or every variable response shape. The
core therefore exposes CAPTCHA input and raw JSON escape hatches rather than
pretending those server-side conditions are fixed.

Endpoint results above reflect one account at one point in time. A `500` here
is a server-side condition, not proof that the request contract is wrong.
