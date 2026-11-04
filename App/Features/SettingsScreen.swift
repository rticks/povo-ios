import SwiftUI
import PovoKit

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: PreferencesStore
    @State private var checking = false
    @State private var downloading = false
    @State private var update: AvailableUpdate?
    @State private var updateMessage: String?
    @State private var downloadedIPA: URL?
    var body: some View {
        Form {
            Section("表示") {
                Picker("テーマ", selection: Binding(get: { preferences.value.theme }, set: { mode in model.changePreferences { $0.theme = mode } })) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("theme-picker")
            }
            Section {
                Toggle("バックグラウンド更新を予約", isOn: Binding(get: { preferences.value.backgroundRefresh }, set: { enabled in model.changePreferences { $0.backgroundRefresh = enabled } }))
            } header: { Text("自動更新") } footer: {
                Text("最短15分後を希望してiOSに予約しますが、実行時刻・間隔はiOSが決定します。低電力モード、強制終了、利用頻度などにより実行されない場合があります。請求・購入履歴の取得は約1時間に間引きます。手動更新ではすべて取得します。")
            }
            Section {
                Toggle("利用停止までの日数を表示", isOn: Binding(get: { preferences.value.suspensionEnabled }, set: { enabled in model.changePreferences { $0.suspensionEnabled = enabled } }))
                Toggle("利用停止が近づいたら通知", isOn: Binding(get: { preferences.value.notifySuspension }, set: { enabled in Task { await model.enableNotifications(enabled) } }))
                    .disabled(!preferences.value.suspensionEnabled)
                Stepper("\(preferences.value.notifyDays) 日前に通知", value: Binding(get: { preferences.value.notifyDays }, set: { days in model.changePreferences { $0.notifyDays = days } }), in: 1...180)
                    .disabled(!preferences.value.suspensionEnabled)
                Link("iOS の通知設定を開く", destination: URL(string: UIApplication.openSettingsURLString)!)
            } header: { Text("180日ルール") } footer: {
                Text("起算日は各回線の詳細画面で登録します。通知は初期状態ではオフです。将来の通知はローカルで予約するため、バックグラウンド更新が行われなくても通知できます。660円ルールの例外は自動判定しません。")
            }
            Section {
                Toggle("残量をウィジェットに共有", isOn: Binding(get: { preferences.value.shareWithWidgets }, set: { enabled in model.changePreferences { $0.shareWithWidgets = enabled } }))
                LabeledContent("App Group", value: model.widgetSharingAvailable ? "利用可能" : "署名の確認が必要")
                NavigationLink("ウィジェットのプレビュー") { WidgetPreviewScreen() }
                Text("一覧型と1回線の円形メーター型に対応します。円形メーターはウィジェットの編集から回線を選択してください。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("ホーム画面ウィジェット") } footer: {
                Text("共有するのは回線ラベル・残量・取得日時だけです。トークンや端末IDは共有しません。App Groupを許可したアプリ本体と拡張の再署名が必要です。無料署名や一部のサイドロード環境ではウィジェットが動作しません。")
            }
            Section("バージョンと更新") {
                LabeledContent("バージョン", value: "\(ReleaseUpdater.currentVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                LabeledContent("配布元", value: ReleaseUpdater.repository)
                Button { Task { await checkForUpdates() } } label: {
                    HStack { Text("更新を確認"); if checking { Spacer(); ProgressView() } }
                }.disabled(checking || downloading)
                if let updateMessage { Text(updateMessage).font(.caption).foregroundStyle(.secondary) }
                if let update {
                    Text("\(update.version) が利用できます").font(.headline)
                    if let notes = update.notes { Text(String(notes.prefix(1200))).font(.caption).foregroundStyle(.secondary) }
                    Button {
                        Task {
                            downloading = true; defer { downloading = false }
                            do { downloadedIPA = try await ReleaseUpdater.download(update) }
                            catch { updateMessage = AppFailure.describing(error).message }
                        }
                    } label: { HStack { Text("IPAをダウンロード"); if downloading { Spacer(); ProgressView() } } }.disabled(downloading)
                }
                if let downloadedIPA { ShareLink("IPAを保存・共有", item: downloadedIPA) }
                Link("GitHub Actions のビルド成果物", destination: ReleaseUpdater.actionsURL)
                Link("GitHub Releases", destination: ReleaseUpdater.releasesURL)
                Text("iOSでは無署名IPAをアプリ自身がインストールできません。取得後に外部の署名・インストール手段を使ってください。更新時はBundle ID、署名元、KeychainとApp Groupの権限を維持しないと認証情報やウィジェット共有が引き継がれない場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #if DEBUG
            Section("開発者向け") { NavigationLink("プロトコル検証") { ProtocolScreen() } }
            #endif
            Section("このアプリについて") {
                Text("非公式の個人用アカウント管理クライアントです。KDDI / povo / Circles.life の提供・承認・サポートを受けていません。")
                    .font(.subheadline)
                Text("アクセス解析・広告SDKはありません。認証情報はこの端末のKeychainに保存し、iCloud同期しません。APIキャッシュと手入力した起算日は別に保存します。")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("ライセンスと移植について") { NoticesScreen() }
            }
        }
        .navigationTitle("設定")
    }
    private func checkForUpdates() async {
        checking = true; updateMessage = nil; update = nil; defer { checking = false }
        do {
            update = try await ReleaseUpdater.check()
            if update == nil { updateMessage = "最新版を使用しています" }
        } catch { updateMessage = AppFailure.describing(error).message }
    }
}

private struct NoticesScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("povo-ios").font(.title.weight(.semibold))
                Text("povo-android の機能を SwiftUI / WidgetKit / BackgroundTasks / Keychain に移植し、通信には同じ povo-core Rustライブラリを UniFFI 経由で使用しています。")
                Link("povo-android", destination: URL(string: "https://github.com/uirooong/povo-android")!)
                Link("povo-core", destination: URL(string: "https://github.com/uirooong/povo-core")!)
                Text(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "ライセンスはリポジトリの THIRD-PARTY-NOTICES.md を参照してください。")
                    .font(.caption).textSelection(.enabled)
            }.padding()
        }.navigationTitle("ライセンス")
    }
}
