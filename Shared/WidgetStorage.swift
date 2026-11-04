import Foundation
import PovoKit

/// Shared with the extension, not with iCloud. No Keychain access group, JWT,
/// device id, invoice, birthday or payment URL is ever exposed to WidgetKit.
enum WidgetStorage {
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "PovoAppGroup") as? String ?? "group.jp.povo.manager.ios" }
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    static var isAvailable: Bool { container != nil }
    static func read() -> WidgetSnapshot {
        guard let container, let data = try? Data(contentsOf: container.appendingPathComponent("usage-v1.json")),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snapshot
    }
    static func write(_ snapshot: WidgetSnapshot) throws {
        guard let container else { throw AppFailure("App Group が許可されていません。ウィジェットには対応する署名が必要です。") }
        let url = container.appendingPathComponent("usage-v1.json")
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var protected = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
    }
    static func deepLink(accountID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "povo-manager"; components.host = "account"
        if let accountID { components.queryItems = [URLQueryItem(name: "id", value: accountID)] }
        return components.url!
    }
}
