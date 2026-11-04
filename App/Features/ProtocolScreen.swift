#if DEBUG
import SwiftUI
import PovoKit

struct ProtocolScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var accountID = ""
    @State private var path = "account/usage/plan/get"
    @State private var prefix = ""
    @State private var version = "v4"
    @State private var bodyJSON = "{}"
    @State private var output = ""
    @State private var busy = false
    @State private var confirmPOST = false
    var body: some View {
        Form {
            Section {
                Text("自分のアカウントの調査専用です。認証フィールドは伏せますが、応答には氏名・メール・請求等の個人情報が含まれます。共有する前に必ず内容を確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("アカウント", selection: $accountID) {
                    ForEach(model.accounts) { Text($0.label).tag($0.id) }
                }
            }
            Section("エンドポイント") {
                TextField("パス（/始まりなら非ローカライズ）", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("prefix（省略可）", text: $prefix).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("version", text: $version).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextEditor(text: $bodyJSON).frame(minHeight: 80).font(.system(.caption, design: .monospaced))
                Button("GET を実行") { Task { await request(post: false) } }.disabled(busy || accountID.isEmpty || path.isEmpty)
                Button("POST を実行…", role: .destructive) { confirmPOST = true }.disabled(busy || accountID.isEmpty || path.isEmpty)
                if busy { ProgressView("通信中…") }
            }
            Section("動作確認済みの取得経路") {
                Button("残量") { path = "account/usage/plan/get"; version = "v4"; prefix = "" }
                Button("請求") { path = "layout/bills/info"; version = "v5"; prefix = "" }
                Button("契約中トッピング") { path = "/api/v1/quilt/page/user-plan-details-v2" }
                Button("購入履歴") { path = "/api/v1/quilt/page/order-history" }
                Button("カタログ") { path = "/api/v1/quilt/page/dashboard-v2" }
                Button("プロフィール画面") { path = "/api/v1/quilt/page/profile" }
                Button("紹介コード") { path = "account/referral/code/get"; version = "v4"; prefix = "" }
            }
            if !output.isEmpty {
                Section("応答（認証情報は伏せ字）") {
                    Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    ShareLink("内容を確認して共有", item: output)
                    Button("表示を消去", role: .destructive) { output = "" }
                }
            }
        }
        .navigationTitle("プロトコル検証").navigationBarTitleDisplayMode(.inline)
        .onAppear { if accountID.isEmpty { accountID = model.accounts.first?.id ?? "" } }
        .confirmationDialog("実際のPOSTリクエストを送信しますか？", isPresented: $confirmPOST, titleVisibility: .visible) {
            Button("指定したPOSTを送信", role: .destructive) { Task { await request(post: true) } }
        } message: { Text("指定先によっては課金や契約変更が発生します。入力したパスとJSONの意味を確認してください。自動再試行はしません。") }
    }
    private func request(post: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            output = try await model.repository.diagnostic(accountID, path: path.trimmingCharacters(in: .whitespacesAndNewlines),
                                                           prefix: prefix.nilIfBlank, version: version.nilIfBlank ?? "v4", body: post ? bodyJSON : nil)
        } catch { output = AppFailure.describing(error).message }
        await model.reload()
    }
}
#endif
