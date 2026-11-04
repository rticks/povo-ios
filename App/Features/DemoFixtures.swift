#if DEBUG
import Foundation
import PovoKit

/// Only reachable through the UI-test launch argument in a Debug build.
/// Entirely synthetic accounts; no real tokens, network, purchases or Keychain.
@MainActor
enum DemoFixtures {
    static func makeModel() -> AppModel {
        let arguments = ProcessInfo.processInfo.arguments
        let records = arguments.contains("--empty") ? [] : [record("demo-main", phone: "090-0000-0001", left: 80), record("demo-sub", phone: "090-0000-0002", left: 3.25)]
        let sessions = records.map { PovoSession(accountID: $0.id, deviceID: "ui-test-device", authToken: "ui-test-placeholder", externalID: $0.id) }
        let cache = MemoryCacheStorage(AccountCache(accounts: records))
        let repository = try! AccountRepository(sessions: MemorySessionStorage(sessions), cache: cache,
                                                factory: { DemoService(accountID: $0.accountID) })
        let defaults = UserDefaults(suiteName: "jp.povo.manager.ui-tests.\(UUID().uuidString)")!
        let preferences = PreferencesStore(defaults: defaults)
        if arguments.contains("--dark") { try? preferences.update { $0.theme = .dark } }
        return AppModel(repository: repository, preferences: preferences, isUITesting: true)
    }
    private static func record(_ id: String, phone: String, left: Double) -> AccountRecord {
        var record = AccountRecord(id: id, profile: AccountProfile(externalID: id, email: id + "@example.invalid", phone: phone,
                                                                 name: "サンプル利用者", sin: "sample-line", planName: "povo2.0",
                                                                 status: "ACTIVE", activationDate: "2026-01-01", birthDate: "2000-01-01"))
        record.usage = PlanUsage(buckets: BucketKind.allCases.map {
            DataBucket(kind: $0, usedKB: $0 == .boost ? (120 - left) * 1_048_576 : 0,
                       leftKB: $0 == .boost ? left * 1_048_576 : 0)
        })
        record.usageFetchedAt = Date(timeIntervalSince1970: 1_793_833_200)
        record.lastRefreshedAt = record.usageFetchedAt
        record.toppings = [Topping(section: "データ", name: "データ追加120GB（365日間）", remaining: "\(left)GB / 120.00GB", expiry: "2027年 2月 28日 午後11:59\n残り 115 日間")]
        var bills = BillsDocument()
        bills.past = [Invoice(id: "sample-bill", billID: "sample-only", title: "2026年10月", status: .paid, amount: Money(value: 180, prefix: "円"), hasPDF: false)]
        record.bills = bills
        record.purchases = [Purchase(orderID: "sample-order", status: "注文完了", orderStatus: "success", purchaseDate: "2026年 2月 28日",
                                     products: [PurchasedProduct(name: "データ追加120GB（365日間）", price: "21,600円")])]
        record.profileInfo = ProfileInfo(paymentMasked: "xxxx-xxxx-xxxx-1234")
        if ProcessInfo.processInfo.arguments.contains("--error"), id == "demo-sub" {
            record.needsLogin = true; record.lastError = "再ログインが必要です（サンプル表示）"
        }
        return record
    }
}

private final class DemoService: AccountService {
    let accountID: String
    init(accountID: String) { self.accountID = accountID }
    var authToken: String? { "ui-test-placeholder" }
    var sin: String? { "sample-line" }
    func refreshToken() throws -> String { "ui-test-placeholder" }
    func profile() throws -> AccountProfile { AccountProfile(externalID: accountID, phone: "090-0000-0001", planName: "povo2.0") }
    func usageJSON() throws -> String { #"{"data":{"boost":{"left":83886080,"used":41943040}}}"# }
    func billsJSON() throws -> String { #"{"past_bills":{"list":[]}}"# }
    func quilt(_ page: String) throws -> String {
        if page == "dashboard-v2" {
            return #"""
            {"widgets":[{"components":[{"type":"addon-section","data":{"sectionHeader":{"title":"データトッピング"},"items":[
              {"data":{"id":"sample-1","name":{"title":"データ追加3GB（30日間）"},"validity":{"title":"3GB / 30日間"},"price":{"title":"990円"}}},
              {"data":{"id":"sample-2","name":{"title":"データ追加120GB（365日間）"},"validity":{"title":"120GB / 365日間"},"price":{"title":"21,600円"}},"action":{"data":{"product_popup":{"id":"sample-2","title":"データ追加120GB（365日間）","price":"21,600円","is_3ds_topping":true}}}}
            ]}}]}]}
            """#
        }
        return #"{"widgets":[]}"#
    }
    func order(sku: String) throws -> ToppingOrder { throw AppFailure("UIテストでは購入しません") }
    func pdf(billID: String) throws -> Data { throw AppFailure("UIテストではPDFを取得しません") }
    func request(path: String, prefix: String?, version: String, body: String?) throws -> String { try usageJSON() }
    func loginActions(email: String?, phone: String?) throws -> [ChallengeKind] { [.email] }
    func sendOTP(kind: ChallengeKind, email: String, phone: String) throws -> String { throw AppFailure("UIテストではOTPを送信しません") }
    func login(email: LoginChallenge?, mobile: LoginChallenge?) throws -> AuthResult { throw AppFailure("UIテストではログインしません") }
    func validatePIN(token: String, pin: String) throws -> AuthResult { throw AppFailure("UIテストではPINを送信しません") }
}
#endif
