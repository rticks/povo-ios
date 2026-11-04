import XCTest
@testable import PovoKit

final class PolicyTests: XCTestCase {
    func testFAQExpiryAndLeapYear() {
        XCTAssertEqual(Suspension.expiry(purchasedOn: "2026-01-01", durationDays: 30), "2026-01-31")
        XCTAssertEqual(Suspension.expiry(purchasedOn: "2026-02-28", durationDays: 365), "2027-02-28")
        XCTAssertEqual(Suspension.expiry(purchasedOn: "2027-06-01", durationDays: 365), "2028-05-31")
    }
    func testSuspensionIsExpiryPlus181AndTerminationPlus30() throws {
        let forecast = try XCTUnwrap(Suspension.forecast(expiry: "2026-01-31", today: CalendarDay("2026-01-31")!))
        XCTAssertEqual(forecast.suspendsOn.description, "2026-07-31")
        XCTAssertEqual(forecast.terminatesOn.description, "2026-08-30")
        XCTAssertEqual(forecast.daysLeft, 181)
    }
    func testSuspensionBoundaryDoesNotClampOverdueToZero() {
        for (today, expected) in [("2026-07-30", 1), ("2026-07-31", 0), ("2026-08-01", -1)] {
            XCTAssertEqual(Suspension.forecast(expiry: "2026-01-31", today: CalendarDay(today)!)?.daysLeft, expected)
        }
    }
    func testInvalidDatesNeverNormaliseIntoValidOnes() {
        for invalid in ["", "2026/02/28", "2026-02-30", "2026-13-01", "0000-01-01", "2026-2-3"] {
            XCTAssertNil(CalendarDay(invalid)); XCTAssertNil(Suspension.expiry(purchasedOn: invalid, durationDays: 30))
        }
        XCTAssertNil(Suspension.expiry(purchasedOn: "2026-01-01", durationDays: 0))
        XCTAssertNil(Suspension.expiry(purchasedOn: "2026-01-01", durationDays: 3651))
        XCTAssertEqual(CalendarDay(" 2026-01-01 ")?.description, "2026-01-01")
    }
    func testCalendarArithmeticAcrossDSTIsStillDays() {
        let day = CalendarDay("2026-03-07")!
        XCTAssertEqual(day.adding(days: 2).description, "2026-03-09")
        XCTAssertEqual(day.days(until: day.adding(days: 2)), 2)
        let local = day.localDate(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(CalendarDay(date: local, timeZone: TimeZone(identifier: "America/Los_Angeles")!), day)
    }
    func testJWTIdentityIsExternalIDNotIssuerAndRefreshOnlyOnExpiry() {
        let token = makeToken(externalID: "account-a", expiry: 2000)
        XCTAssertEqual(JWT.externalID(token), "account-a")
        XCTAssertFalse(JWT.isExpired(token, now: Date(timeIntervalSince1970: 1999)))
        XCTAssertTrue(JWT.isExpired(token, now: Date(timeIntervalSince1970: 2000)))
        XCTAssertTrue(JWT.isExpired("bad"))
        XCTAssertNil(JWT.externalID("bad"))
    }
    func testBillsThrottleUsesAttemptNotNonemptyInvoices() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertTrue(BillsPolicy.ifStale.wants(lastAttempt: nil, now: now))
        XCTAssertFalse(BillsPolicy.ifStale.wants(lastAttempt: now.addingTimeInterval(-3299), now: now))
        XCTAssertTrue(BillsPolicy.ifStale.wants(lastAttempt: now.addingTimeInterval(-3300), now: now))
        XCTAssertTrue(BillsPolicy.always.wants(lastAttempt: now, now: now))
    }
    func testVersionComparisonIsNumericAndRejectsMalformedAndPrereleases() {
        XCTAssertTrue(ReleaseVersion.isNewer("v0.10.0", than: "0.9.0"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1", than: "0.1.0"))
        for invalid in ["", "v", "1..2", "1.2beta", "2.0.0-beta.1", "huge"] {
            XCTAssertFalse(ReleaseVersion.isNewer(invalid, than: "0.1.0"))
        }
    }
    func testWidgetExportContainsNoSessionSecrets() throws {
        var record = AccountRecord(id: "account", profile: AccountProfile(email: "fake@example.invalid", birthDate: "2000-01-01"))
        record.usage = PlanUsage(buckets: [DataBucket(kind: .boost, usedKB: 10, leftKB: 20)])
        let text = String(decoding: try JSONEncoder().encode(WidgetAccount(record: record)), as: UTF8.self)
        XCTAssertFalse(text.contains("birthDate")); XCTAssertFalse(text.contains("authToken")); XCTAssertFalse(text.contains("deviceID"))
        XCTAssertEqual(WidgetAccount(record: record).fraction!, 2.0 / 3, accuracy: 0.0001)
        XCTAssertNil(WidgetAccount(record: AccountRecord(id: "unknown")).leftKB)
    }
    private func makeToken(externalID: String, expiry: Int) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["external_id": externalID, "iss": "circles", "exp": expiry])
        return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
    }
}

final class WebPolicyTests: XCTestCase {
    let page = PovoWebPage(kind: .payment, link: "https://shop.povo.jp/manage/payment-details?webview=1&update_from=mobile", exitURL: "/updateCardSuccess", needsXAuth: true)
    func testEntryGetsEntireSessionContractAndDoesNotDuplicateKeys() throws {
        let url = try XCTUnwrap(WebPolicy.entry(page: page, token: "test-token", deviceID: "test-device"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        for name in ["device_id", "auth_token", "webview", "native", "reset", "use_native_ekyc_api", "app_version", "return_url"] {
            XCTAssertEqual(items.filter { $0.name == name }.count, 1, name)
        }
        XCTAssertEqual(items.first { $0.name == "device_id" }?.value, "test-device")
        XCTAssertEqual(items.first { $0.name == "update_from" }?.value, "mobile")
    }
    func testServerURLNeverWinsOverFreshCredentials() throws {
        var page = page; page.link += "&auth_token=stale&device_id=other"
        let url = try XCTUnwrap(WebPolicy.entry(page: page, token: "fresh", deviceID: "own"))
        XCTAssertTrue(url.absoluteString.contains("auth_token=fresh")); XCTAssertFalse(url.absoluteString.contains("stale"))
    }
    func testUnauthenticatedPageCannotLeakCredentials() throws {
        var page = page; page.needsXAuth = false; page.link += "&auth_token=stale&device_id=other"
        let url = try XCTUnwrap(WebPolicy.entry(page: page, token: "fresh", deviceID: "own"))
        XCTAssertFalse(url.absoluteString.contains("auth_token")); XCTAssertFalse(url.absoluteString.contains("device_id"))
        XCTAssertTrue(url.absoluteString.contains("return_url"))
    }
    func testRejectsConfusableOrInsecureHosts() {
        for text in ["https://povo.jp.evil.invalid/manage/payment-details", "http://shop.povo.jp/manage/payment-details", "https://povo.jp@evil.invalid/manage/payment-details", "https://shop.povo.jp:444/manage/payment-details", "file:///povo.jp"] {
            XCTAssertFalse(WebPolicy.isPovo(URL(string: text)!))
            var page = page; page.link = text
            XCTAssertNil(WebPolicy.entry(page: page, token: "token", deviceID: "id"))
        }
        XCTAssertNil(WebPolicy.entry(page: page, token: nil, deviceID: "id"))
    }
    func testPageKindIsExactNotPrefix() {
        XCTAssertEqual(WebPageKind.matching("https://shop.povo.jp/manage/order?x=1"), .contract)
        XCTAssertNil(WebPageKind.matching("https://shop.povo.jp/manage/order-history"))
    }
    func test3DSReturnChecksHTTPSHostPortAndExactPath() {
        XCTAssertTrue(WebPolicy.matchesReturn(URL(string: "https://povo.jp/success?status=ok")!))
        for url in ["http://povo.jp/success", "https://povo.jp.evil.invalid/success", "https://povo.jp/not-success", "https://povo.jp:444/success"] {
            XCTAssertFalse(WebPolicy.matchesReturn(URL(string: url)!))
        }
    }
    func testWebExitIsNotAnUntrustedSubstring() {
        XCTAssertTrue(WebPolicy.matchesExit(URL(string: "https://shop.povo.jp/updateCardSuccess?x=1")!, path: "/updateCardSuccess"))
        XCTAssertFalse(WebPolicy.matchesExit(URL(string: "https://evil.invalid/updateCardSuccess")!, path: "/updateCardSuccess"))
        XCTAssertFalse(WebPolicy.matchesExit(URL(string: "https://shop.povo.jp/not-updateCardSuccess")!, path: "/updateCardSuccess"))
    }
    func testBrowserSchemeOnlyReplacesSchemeAndRefusesSecrets() {
        XCTAssertEqual(WebPolicy.externalURL(URL(string: "browser://povo.jp/browser-guide")!)?.absoluteString, "https://povo.jp/browser-guide")
        XCTAssertNil(WebPolicy.externalURL(URL(string: "browser://example.invalid/?auth_token=secret")!))
        XCTAssertFalse(WebPolicy.isContact(URL(string: "intent://evil")!))
        XCTAssertTrue(WebPolicy.isContact(URL(string: "tel:123")!))
    }
    func testRotationAndCallbackValidation() {
        XCTAssertEqual(WebPolicy.rotatedToken(URL(string: "webfront://callback?auth_token=rotated")!), "rotated")
        XCTAssertNil(WebPolicy.rotatedToken(URL(string: "https://povo.jp/?auth_token=x")!))
        XCTAssertTrue(WebPolicy.safeCallback("setAndroidAccessToken"))
        XCTAssertFalse(WebPolicy.safeCallback("x);steal()//"))
        XCTAssertEqual(WebPolicy.quotedJS("\"\\\n"), #""\"\\\n""#)
    }
    func testDiagnosticsRedactNestedCredentialsAndTokenURLs() {
        let raw = #"{"result":{"auth_token":"top-secret","other":[{"device_id":"secret-device"}],"link":"https://povo.jp/?auth_token=secret&x=1"},"email":"fake@example.invalid"}"#
        let redacted = DiagnosticRedactor.redact(raw)
        XCTAssertFalse(redacted.contains("top-secret")); XCTAssertFalse(redacted.contains("secret-device"))
        XCTAssertFalse(redacted.contains("auth_token=secret"))
        XCTAssertTrue(redacted.contains("fake@example.invalid")) // no false anonymisation claim
    }
}
