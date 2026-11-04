import Foundation
import Combine
import PovoKit

@MainActor
final class PreferencesStore: ObservableObject {
    @Published private(set) var value: AppPreferences
    @Published private(set) var anchors: [String: SuspensionAnchor]
    private let defaults: UserDefaults
    private let prefix: String
    private(set) var loadWarning: String?
    init(defaults: UserDefaults = .standard, prefix: String = "povo.v1") {
        self.defaults = defaults; self.prefix = prefix
        value = AppPreferences(); anchors = [:]
        if let data = defaults.data(forKey: prefix + ".settings") {
            if let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) { value = decoded }
            else { loadWarning = "設定を読み取れませんでした。保存済みの起算日は自動削除しません。" }
        }
        if let data = defaults.data(forKey: prefix + ".anchors") {
            if let decoded = try? JSONDecoder().decode([String: SuspensionAnchor].self, from: data) { anchors = decoded }
            else { loadWarning = "起算日を読み取れませんでした。元データは保持しています。" }
        }
        value.notifyDays = min(180, max(1, value.notifyDays))
    }
    func update(_ change: (inout AppPreferences) -> Void) throws {
        var next = value; change(&next)
        next.notifyDays = min(180, max(1, next.notifyDays))
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: prefix + ".settings"); value = next
    }
    func setAnchor(_ anchor: SuspensionAnchor?, for id: String) throws {
        var next = anchors
        if var anchor {
            // Editing the same anchor does not re-arm an already shown warning.
            if anchors[id]?.expiryDate == anchor.expiryDate { anchor.notifiedFor = anchors[id]?.notifiedFor }
            next[id] = anchor
        } else { next.removeValue(forKey: id) }
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: prefix + ".anchors"); anchors = next
    }
    func markNotified(_ id: String, date: String) throws {
        guard anchors[id] != nil else { return }
        var next = anchors; next[id]?.notifiedFor = date
        defaults.set(try JSONEncoder().encode(next), forKey: prefix + ".anchors"); anchors = next
    }
}
