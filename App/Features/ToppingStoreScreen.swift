import SwiftUI
import WebKit
import PovoKit

struct PaymentChallenge: Identifiable {
    let id = UUID()
    let product: ToppingProduct
    let order: ToppingOrder
}

struct ThreeDSScreen: View {
    let challenge: PaymentChallenge
    let onReturn: () -> Void
    let onCancel: () -> Void
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading { ProgressView().progressViewStyle(.linear).padding(.horizontal) }
                Text("カード会社の認証ページです。アプリの認証情報は渡しません。画面を閉じた場合も、再購入する前に購入履歴を確認してください。")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
                if let error { Text(error).font(.subheadline).foregroundStyle(.red).padding() }
                if let text = challenge.order.challengeURL, let url = URL(string: text), WebPolicy.isHTTPS(url) {
                    ChallengeWebView(url: url, onLoading: { loading = $0 }, onError: { error = $0 }, onReturn: onReturn)
                } else { ContentUnavailableView("認証URLを開けません", systemImage: "lock.shield") }
            }
            .navigationTitle("お支払いの認証").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("認証を閉じる", action: onCancel) } }
        }
        .interactiveDismissDisabled()
    }
}

/// A completely separate web view: no message handlers, user scripts, session
/// headers, cookies, custom user agent or token-bearing bridge from account UI.
private struct ChallengeWebView: UIViewRepresentable {
    let url: URL
    let onLoading: (Bool) -> Void
    let onError: (String) -> Void
    let onReturn: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true; view.isInspectable = false
        view.load(URLRequest(url: url)); return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading(); uiView.navigationDelegate = nil; uiView.uiDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: ChallengeWebView
        private var returned = false
        init(parent: ChallengeWebView) { self.parent = parent }
        private func finish() { if !returned { returned = true; parent.onReturn() } }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame != false, WebPolicy.matchesReturn(url) { finish(); decisionHandler(.cancel); return }
            if WebPolicy.isHTTPS(url) || url.absoluteString == "about:blank" { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.onLoading(true) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoading(false); if let url = webView.url, WebPolicy.matchesReturn(url) { finish() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onError("カード会社のページを読み込めませんでした。購入履歴をご確認ください。") }
            parent.onLoading(false)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoading(false); parent.onError("カード会社のページの読み込みに失敗しました")
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }; return nil
        }
    }
}

@MainActor
final class ToppingStoreViewModel: ObservableObject {
    @Published var sections: [ToppingSection] = []
    @Published var loading = false
    @Published var error: String?
    @Published var confirming: ToppingProduct?
    @Published var placing = false
    @Published var challenge: PaymentChallenge?
    @Published var result: String?
    func load(accountID: String, repository: AccountRepository) async {
        guard !loading, !placing else { return }
        loading = true; error = nil; defer { loading = false }
        do { sections = try await repository.catalogue(accountID) }
        catch { self.error = AppFailure.describing(error).message }
    }
    func confirm(_ product: ToppingProduct, accountID: String, model: AppModel) {
        guard !placing, challenge == nil, product.price?.nilIfBlank != nil else { return }
        confirming = nil; placing = true; result = nil; error = nil
        Task {
            defer { placing = false }
            do {
                let latest = try await model.repository.catalogue(accountID)
                guard let current = latest.flatMap(\.products).first(where: { $0.id == product.id }),
                      current.price == product.price, current.name == product.name else {
                    sections = latest
                    self.error = "価格または商品情報が変わりました。最新の内容を選び直してください。購入リクエストは送信していません。"
                    return
                }
                let order = try await model.repository.order(accountID, sku: product.id)
                if order.needsChallenge { challenge = PaymentChallenge(product: product, order: order) }
                else {
                    result = "購入が受け付けられました。反映状況は残量・購入履歴で確認してください。"
                    await model.refresh(accountID)
                }
            } catch {
                self.error = AppFailure.describing(error).message + "\n購入が完了している可能性もあるため、再購入する前に購入履歴を確認してください。自動再送はしません。"
                await model.reload()
            }
        }
    }
    func returned(accountID: String, model: AppModel) {
        guard let completed = challenge else { return }
        challenge = nil; placing = true
        Task {
            defer { placing = false }
            await model.refresh(accountID)
            let record = model.accounts.first { $0.id == accountID }
            if let ref = completed.order.orderRef,
               record?.purchases.contains(where: { $0.orderID == ref && $0.succeeded }) == true {
                result = "購入履歴で注文完了を確認しました。"
            } else {
                result = "認証ページから戻りました。購入の確定はまだ確認できていません。povoの購入履歴への反映をご確認ください。再購入は自動では行いません。"
            }
        }
    }
    func cancelled(accountID: String, model: AppModel) {
        challenge = nil
        result = "認証画面を閉じました。購入を再送していません。成否は購入履歴で確認してください。"
        Task { await model.refresh(accountID) }
    }
}

struct ToppingStoreScreen: View {
    let accountID: String
    @EnvironmentObject private var model: AppModel
    @StateObject private var vm = ToppingStoreViewModel()
    private var label: String { model.accounts.first { $0.id == accountID }?.label ?? accountID }
    var body: some View {
        List {
            Section {
                LabeledContent("購入する回線", value: label)
                Text("価格は povo が今回提示した表記をそのまま表示しています。購入ボタンの後に確認が表示されます。")
                    .font(.caption).foregroundStyle(.secondary)
                if vm.loading || vm.placing { HStack { ProgressView(); Text(vm.placing ? "購入処理中…（再送しないでください）" : "カタログを取得中…") }.font(.subheadline) }
                if let error = vm.error { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline) }
                if let result = vm.result { Label(result, systemImage: "info.circle").font(.subheadline).accessibilityIdentifier("purchase-result") }
            }
            ForEach(Array(vm.sections.enumerated()), id: \.offset) { _, section in
                Section(section.title ?? "トッピング") {
                    ForEach(section.products) { product in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(product.name).font(.headline)
                            if let validity = product.validity { Text(validity).font(.subheadline).foregroundStyle(.secondary) }
                            HStack(alignment: .firstTextBaseline) {
                                Text(product.price ?? "価格を取得できません").font(.title3.weight(.semibold))
                                Spacer()
                                Button("購入") { vm.confirming = product }
                                    .buttonStyle(.bordered).disabled(vm.placing || vm.loading || product.price == nil || model.isUITesting)
                            }
                            if product.requires3DS { Label("カード会社の認証が必要な場合があります", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 8)
                    }
                }
            }
            if vm.sections.isEmpty, !vm.loading { ContentUnavailableView("購入できるトッピングがありません", systemImage: "cart") }
        }
        .navigationTitle("トッピングストア").navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(accountID: accountID, repository: model.repository) }
        .refreshable { await vm.load(accountID: accountID, repository: model.repository) }
        .alert("トッピングを購入しますか？", isPresented: Binding(get: { vm.confirming != nil }, set: { if !$0 { vm.confirming = nil } }), presenting: vm.confirming) { product in
            Button("\(product.price ?? "")で購入") { vm.confirm(product, accountID: accountID, model: model) }
            Button("やめる", role: .cancel) { vm.confirming = nil }
        } message: { product in
            Text("回線：\(label)\n\(product.name)\n\(product.price ?? "")\n\n確認すると実際の購入リクエストが送信されます。3DSが不要な場合は直ちに購入が成立します。")
        }
        .sheet(item: $vm.challenge) { challenge in
            ThreeDSScreen(challenge: challenge, onReturn: { vm.returned(accountID: accountID, model: model) },
                          onCancel: { vm.cancelled(accountID: accountID, model: model) })
        }
        .interactiveDismissDisabled(vm.placing)
    }
}
