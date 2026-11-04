import SwiftUI
import BackgroundTasks
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return true }
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundRefresh.identifier, using: nil) { task in
            let completion = BackgroundCompletion(task: task)
            let work = Task { @MainActor in
                let model = AppModel.shared
                await model.reload()
                let success = await model.refreshAll(policy: .ifStale)
                BackgroundRefresh.schedule(enabled: model.preferences.value.backgroundRefresh)
                completion.finish(success: success && !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel(); completion.finish(success: false) }
        }
        return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        BackgroundRefresh.schedule(enabled: AppModel.shared.preferences.value.backgroundRefresh)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["accountID"] as? String else { return }
        let model = AppModel.shared
        await model.reload()
        if model.accounts.contains(where: { $0.id == id }) { model.selectedAccountID = id }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

private final class BackgroundCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let task: BGTask
    init(task: BGTask) { self.task = task }
    func finish(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }; completed = true
        task.setTaskCompleted(success: success)
    }
}

@main
struct PovoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            _model = StateObject(wrappedValue: DemoFixtures.makeModel()); return
        }
        #endif
        _model = StateObject(wrappedValue: AppModel.shared)
    }
    var body: some Scene {
        WindowGroup {
            AppShell().environmentObject(model).environmentObject(model.preferences)
        }
    }
}

struct AppShell: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    private var scheme: ColorScheme? {
        switch preferences.value.theme {
        case .system: return nil
        case .light, .povo: return .light
        case .dark: return .dark
        }
    }
    var body: some View {
        TabView(selection: $tab) {
            AccountsScreen().tabItem { Label("アカウント", systemImage: "simcard.2") }.tag(0)
            NavigationStack { SettingsScreen() }.tabItem { Label("設定", systemImage: "gearshape") }.tag(1)
        }
        .preferredColorScheme(scheme)
        .tint(preferences.value.theme == .povo ? PovoStyle.brandInk : .accentColor)
        .task { await model.bootstrap() }
        .onChange(of: phase) { _, next in if next == .active { Task { await model.foreground() } } }
        .onChange(of: model.selectedAccountID) { _, id in if id != nil { tab = 0 } }
        .onOpenURL { model.open($0); tab = 0 }
        .alert("お知らせ", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("閉じる", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}
