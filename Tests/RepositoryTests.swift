import XCTest
import PovoKit
@testable import Povo

final class RepositoryTests: XCTestCase {
    private func session(_ id: String, expired: Bool = false) -> PovoSession {
        PovoSession(accountID: id, deviceID: "device-\(id)", authToken: testJWT(id, expiry: expired ? 1 : 4_000_000_000), externalID: id)
    }
    func testNativeFFIAndRandomIdentityWithoutNetwork() throws {
        let device = try DeviceIdentity.generate()
        XCTAssertEqual(device.count, 32)
        XCTAssertNotEqual(device, try DeviceIdentity.generate())
        let client = PovoClient(deviceId: device, appVersion: WebPolicy.protocolVersion)
        XCTAssertEqual(client.deviceId(), device)
        XCTAssertNil(client.authToken())
        let token = testJWT("native", expiry: 4_000_000_000)
        client.setAuthToken(token: token)
        XCTAssertEqual(client.expiresAt(), 4_000_000_000)
        client.setServiceInstanceNumber(sin: "sample-line")
        XCTAssertEqual(client.serviceInstanceNumber(), "sample-line")
        client.clearAuthToken(); XCTAssertNil(client.authToken())
    }
    func testKeychainRoundTripAndDeletionUseUniqueService() throws {
        let storage = KeychainSessionStorage(service: "jp.povo.manager.tests.\(UUID().uuidString)")
        defer { try? storage.save([]) }
        let values = [session("one"), session("two")]
        try storage.save(values)
        XCTAssertEqual(try storage.load(), values)
        try storage.save([]); XCTAssertTrue(try storage.load().isEmpty)
    }
    func testParallelRenewalsDoNotLoseAnotherAccountsToken() async throws {
        let original = [session("one", expired: true), session("two", expired: true)]
        let storage = MemorySessionStorage(original)
        let services = FixtureServices()
        let repo = try AccountRepository(sessions: storage, cache: MemoryCacheStorage(), factory: services.factory)
        let outcomes = await repo.refreshAll()
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.status == .ok })
        let saved = try storage.load()
        for id in ["one", "two"] {
            XCTAssertNotEqual(saved.first { $0.accountID == id }?.authToken, original.first { $0.accountID == id }?.authToken)
            XCTAssertEqual(saved.first { $0.accountID == id }?.sin, "line-\(id)")
            XCTAssertEqual(services.count(id + ".renew"), 1)
        }
    }
    func testAtMostThreeAccountsInFlight() async throws {
        let services = FixtureServices()
        let repo = try AccountRepository(sessions: MemorySessionStorage((0..<8).map { session("a\($0)") }),
                                         cache: MemoryCacheStorage(), factory: services.factory)
        let outcomes = await repo.refreshAll()
        XCTAssertEqual(outcomes.count, 8)
        XCTAssertTrue(outcomes.allSatisfy { $0.status == .ok })
        XCTAssertLessThanOrEqual(services.maximumActive, 3)
        XCTAssertGreaterThan(services.maximumActive, 0)
    }
    func testConcurrentRefreshOfSameAccountIsCoalesced() async throws {
        let services = FixtureServices()
        let repo = try AccountRepository(sessions: MemorySessionStorage([session("a")]), cache: MemoryCacheStorage(), factory: services.factory)
        async let first = repo.refreshAccount("a")
        async let second = repo.refreshAccount("a")
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy { $0.status == .ok })
        XCTAssertEqual(services.count("a.profile"), 1)
    }
    func testMalformedUsagePreservesLastGoodSnapshot() async throws {
        var old = AccountRecord(id: "a")
        old.usage = PlanUsage(buckets: [DataBucket(kind: .boost, usedKB: 1, leftKB: 99)])
        let services = FixtureServices(); services.setUsage(#"{"unexpected":true}"#)
        let repo = try AccountRepository(sessions: MemorySessionStorage([session("a")]), cache: MemoryCacheStorage(AccountCache(accounts: [old])), factory: services.factory)
        let outcome = await repo.refreshAccount("a")
        let record = try await repo.snapshot().first
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(record?.usage?.totalLeftKB, 99)
        XCTAssertNotNil(record?.lastError)
    }
    func testOptionalBillingFailureDoesNotDiscardFreshUsage() async throws {
        let services = FixtureServices(); services.failBills(true)
        let repo = try AccountRepository(sessions: MemorySessionStorage([session("a")]), cache: MemoryCacheStorage(), factory: services.factory)
        _ = await repo.refreshAccount("a")
        let record = try await repo.snapshot().first
        XCTAssertEqual(record?.usage?.totalLeftKB, 42)
        XCTAssertNotNil(record?.billsAttemptedAt)
        XCTAssertNotNil(record?.lastError)
    }
    func testEmptyBillsAreThrottledByAttemptAndManualRefreshOverrides() async throws {
        let services = FixtureServices()
        let repo = try AccountRepository(sessions: MemorySessionStorage([session("a")]), cache: MemoryCacheStorage(), factory: services.factory)
        _ = await repo.refreshAccount("a", policy: .ifStale)
        _ = await repo.refreshAccount("a", policy: .ifStale)
        XCTAssertEqual(services.count("a.bills"), 1)
        _ = await repo.refreshAccount("a", policy: .always)
        XCTAssertEqual(services.count("a.bills"), 2)
    }
    func testTokenRenewalIsPersistedEvenIfNextRequestFails() async throws {
        let original = session("a", expired: true)
        let storage = MemorySessionStorage([original])
        let services = FixtureServices(); services.setUsage("bad")
        let repo = try AccountRepository(sessions: storage, cache: MemoryCacheStorage(), factory: services.factory)
        _ = await repo.refreshAccount("a")
        XCTAssertNotEqual(try storage.load().first?.authToken, original.authToken)
    }
    func testReloginCannotBeOverwrittenByOldRefresh() async throws {
        let entered = expectation(description: "old client in profile")
        let release = DispatchSemaphore(value: 0)
        let services = FixtureServices()
        services.setProfileHook { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
        let storage = MemorySessionStorage([session("a")])
        let repo = try AccountRepository(sessions: storage, cache: MemoryCacheStorage(), factory: services.factory)
        let oldRefresh = Task { await repo.refreshAccount("a") }
        await fulfillment(of: [entered], timeout: 5)
        _ = try await repo.register(token: testJWT("a", expiry: 4_000_000_001), deviceID: "new-device", profile: AccountProfile(externalID: "a", phone: "new-phone"), email: nil, phone: nil, replacing: "a")
        release.signal()
        let result = await oldRefresh.value
        XCTAssertEqual(result.status, .superseded)
        XCTAssertEqual(try storage.load().first?.deviceID, "new-device")
        let records = try await repo.snapshot()
        XCTAssertEqual(records.first?.profile.phone, "new-phone")
    }
    func testRemovedAccountIsNotResurrectedByLateResponse() async throws {
        let entered = expectation(description: "client in profile")
        let release = DispatchSemaphore(value: 0)
        let services = FixtureServices()
        services.setProfileHook { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
        let storage = MemorySessionStorage([session("a")])
        let repo = try AccountRepository(sessions: storage, cache: MemoryCacheStorage(), factory: services.factory)
        let task = Task { await repo.refreshAccount("a") }
        await fulfillment(of: [entered], timeout: 5)
        try await repo.remove("a"); release.signal()
        _ = await task.value
        XCTAssertTrue(try storage.load().isEmpty)
        let records = try await repo.snapshot(); XCTAssertTrue(records.isEmpty)
    }
    func testWebRotationRejectsAnotherAccount() async throws {
        let original = session("a")
        let storage = MemorySessionStorage([original])
        let services = FixtureServices()
        let repo = try AccountRepository(sessions: storage, cache: MemoryCacheStorage(), factory: services.factory)
        do {
            try await repo.adoptWebToken("a", token: testJWT("other", expiry: 4_000_000_000), generation: original.generation)
            XCTFail("cross-account rotation accepted")
        } catch { }
        XCTAssertEqual(try storage.load().first?.authToken, original.authToken)
    }
    @MainActor
    func testAnchorAndPreferencesSurviveCacheReplacement() throws {
        let defaults = UserDefaults(suiteName: "jp.povo.tests.\(UUID().uuidString)")!
        let first = PreferencesStore(defaults: defaults)
        try first.setAnchor(SuspensionAnchor(purchaseDate: "2026-01-01", durationDays: 30, expiryDate: "2026-01-31"), for: "a")
        try first.markNotified("a", date: "2026-07-31")
        try first.update { $0.notifyDays = 1000; $0.theme = .dark }
        let restored = PreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.anchors["a"]?.expiryDate, "2026-01-31")
        XCTAssertEqual(restored.anchors["a"]?.notifiedFor, "2026-07-31")
        XCTAssertEqual(restored.value.notifyDays, 180)
        XCTAssertEqual(restored.value.theme, .dark)
    }
}

private func testJWT(_ id: String, expiry: Int64) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["external_id": id, "exp": expiry, "nonce": UUID().uuidString])
    return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
}

private final class FixtureServices: @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var active = 0
    private var maxActive = 0
    private var usage = #"{"data":{"boost":{"left":42,"used":8}}}"#
    private var billsFail = false
    private var profileHook: (@Sendable () -> Void)?
    var factory: ServiceFactory { { [self] in FixtureService(session: $0, owner: self) } }
    var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return maxActive }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counters[key, default: 0] }
    func increment(_ key: String) { lock.lock(); defer { lock.unlock() }; counters[key, default: 0] += 1 }
    func setUsage(_ raw: String) { lock.lock(); defer { lock.unlock() }; usage = raw }
    func failBills(_ value: Bool) { lock.lock(); defer { lock.unlock() }; billsFail = value }
    func setProfileHook(_ hook: @escaping @Sendable () -> Void) { lock.lock(); defer { lock.unlock() }; profileHook = hook }
    func usageJSON() -> String { lock.lock(); defer { lock.unlock() }; return usage }
    func billsJSON() throws -> String {
        lock.lock(); let fail = billsFail; lock.unlock()
        if fail { throw AppFailure("billing unavailable") }
        return #"{"past_bills":{"list":[]}}"#
    }
    func enterProfile() {
        lock.lock(); active += 1; maxActive = max(maxActive, active); let hook = profileHook; lock.unlock()
        hook?(); Thread.sleep(forTimeInterval: 0.03)
    }
    func leaveProfile() { lock.lock(); defer { lock.unlock() }; active -= 1 }
}
private final class FixtureService: AccountService {
    let session: PovoSession
    let owner: FixtureServices
    var authToken: String?
    var sin: String?
    init(session: PovoSession, owner: FixtureServices) { self.session = session; self.owner = owner; authToken = session.authToken; sin = session.sin }
    func refreshToken() throws -> String {
        owner.increment(session.accountID + ".renew")
        let token = testJWT(session.accountID, expiry: 4_000_000_000); authToken = token; return token
    }
    func profile() throws -> AccountProfile {
        owner.increment(session.accountID + ".profile"); owner.enterProfile(); defer { owner.leaveProfile() }
        sin = "line-\(session.accountID)"
        return AccountProfile(externalID: session.accountID, phone: "phone-\(session.accountID)", sin: sin)
    }
    func usageJSON() throws -> String { owner.usageJSON() }
    func billsJSON() throws -> String { owner.increment(session.accountID + ".bills"); return try owner.billsJSON() }
    func quilt(_ page: String) throws -> String { #"{"widgets":[]}"# }
    func order(sku: String) throws -> ToppingOrder { throw AppFailure("No purchases in tests") }
    func pdf(billID: String) throws -> Data { Data() }
    func request(path: String, prefix: String?, version: String, body: String?) throws -> String { "{}" }
    func loginActions(email: String?, phone: String?) throws -> [ChallengeKind] { [.email] }
    func sendOTP(kind: ChallengeKind, email: String, phone: String) throws -> String { "test-auth-id" }
    func login(email: LoginChallenge?, mobile: LoginChallenge?) throws -> AuthResult { AuthResult(token: authToken!) }
    func validatePIN(token: String, pin: String) throws -> AuthResult { AuthResult(token: authToken!) }
}
