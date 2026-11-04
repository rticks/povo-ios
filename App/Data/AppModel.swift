import SwiftUI
import WidgetKit
import BackgroundTasks
import PovoKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let repository: AccountRepository
    let preferences: PreferencesStore
    let notifier = SuspensionNotifier()
    let isUITesting: Bool
    @Published var accounts: [AccountRecord] = []
    @Published var refreshing = Set<String>()
    @Published var refreshingAll = false
    @Published var message: String?
    @Published var selectedAccountID: String?
    @Published var widgetSharingAvailable = false
    private var started = false
    private var pendingOpenAccountID: String?

    init(repository: AccountRepository? = nil, preferences: PreferencesStore? = nil, isUITesting: Bool = false) {
        // Default cache storage is recoverable and does not touch Keychain until
        // load. A locked or broken Keychain is surfaced, never replaced/reset.
        self.repository = repository ?? (try! AccountRepository())
        self.preferences = preferences ?? PreferencesStore()
        self.isUITesting = isUITesting
    }
    func bootstrap() async {
        guard !started else { return }; started = true
        await reload()
        if let warning = preferences.loadWarning { message = warning }
        if !isUITesting {
            _ = await refreshAll(policy: .ifStale)
            BackgroundRefresh.schedule(enabled: preferences.value.backgroundRefresh)
        }
    }
    func reload() async {
        do {
            accounts = try await repository.snapshot()
            if let id = pendingOpenAccountID, accounts.contains(where: { $0.id == id }) {
                pendingOpenAccountID = nil; selectedAccountID = id
            }
        } catch { message = AppFailure.describing(error).message }
        await updateIntegrations()
    }
    @discardableResult
    func refreshAll(policy: BillsPolicy = .always) async -> Bool {
        guard !refreshingAll else { return false }
        refreshingAll = true; refreshing.formUnion(accounts.map(\.id))
        defer { refreshingAll = false; refreshing.subtract(accounts.map(\.id)) }
        let outcomes = await repository.refreshAll(policy: policy)
        await reload()
        let failures = outcomes.filter { $0.status == .failed || $0.status == .needsLogin }
        if !failures.isEmpty { message = "\(failures.count) 件の更新に問題があります。各回線の表示を確認してください。" }
        return !outcomes.isEmpty && outcomes.allSatisfy { $0.status == .ok }
    }
    func refresh(_ id: String) async {
        guard !refreshing.contains(id) else { return }
        refreshing.insert(id); defer { refreshing.remove(id) }
        let outcome = await repository.refreshAccount(id)
        await reload()
        if outcome.status != .ok, let detail = outcome.message { message = detail }
    }
    func foreground() async {
        guard started, !isUITesting, !refreshingAll else { return }
        if accounts.contains(where: { $0.lastRefreshedAt.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true }) {
            _ = await refreshAll(policy: .ifStale)
        } else { await updateIntegrations() }
    }
    func remove(_ id: String) async throws {
        try await repository.remove(id)
        try preferences.setAnchor(nil, for: id)
        notifier.remove(accountID: id)
        if selectedAccountID == id { selectedAccountID = nil }
        await reload()
    }
    func changePreferences(_ change: (inout AppPreferences) -> Void) {
        do {
            try preferences.update(change)
            BackgroundRefresh.schedule(enabled: preferences.value.backgroundRefresh)
            Task { await updateIntegrations() }
        } catch { message = AppFailure.describing(error).message }
    }
    func enableNotifications(_ enabled: Bool) async {
        if !enabled { changePreferences { $0.notifySuspension = false }; return }
        do {
            guard try await notifier.requestPermission() else {
                message = "通知が許可されていません。iOS の設定から povo マネージャーの通知を許可してください。"; return
            }
            changePreferences { $0.notifySuspension = true }
        } catch { message = AppFailure.describing(error).message }
    }
    func setAnchor(_ value: SuspensionAnchor?, for id: String) {
        do { try preferences.setAnchor(value, for: id); Task { await updateIntegrations() } }
        catch { message = AppFailure.describing(error).message }
    }
    func open(_ url: URL) {
        guard url.scheme == "povo-manager", url.host == "account" else { return }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
            if accounts.contains(where: { $0.id == id }) { selectedAccountID = id }
            else { pendingOpenAccountID = id }
        }
    }
    private func updateIntegrations() async {
        guard !isUITesting else { return }
        widgetSharingAvailable = WidgetStorage.isAvailable
        if widgetSharingAvailable {
            do {
                try WidgetStorage.write(WidgetSnapshot(accounts: preferences.value.shareWithWidgets ? accounts.map(WidgetAccount.init(record:)) : []))
                WidgetCenter.shared.reloadAllTimelines()
            } catch { message = AppFailure.describing(error).message }
        }
        do { try await notifier.sync(accounts: accounts, preferences: preferences) }
        catch { message = "利用停止通知を予約できませんでした：\(AppFailure.describing(error).message)" }
    }
}

enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "jp.povo.manager.ios") + ".refresh" }
    static func schedule(enabled: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // iOS may deny a request (disabled background refresh, simulator). The
        // settings screen explains that scheduling is never a 15-minute promise.
        try? BGTaskScheduler.shared.submit(request)
    }
}
