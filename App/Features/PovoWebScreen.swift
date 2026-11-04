import SwiftUI
import WebKit
import PovoKit

struct WebSessionContext: Identifiable, Sendable {
    let id = UUID()
    let accountID: String
    let page: PovoWebPage
    let token: String?
    let deviceID: String?
    let generation: UUID?
}

struct PovoWebScreen: View {
    let context: WebSessionContext
    let repository: AccountRepository
    let onDone: () -> Void
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading { ProgressView().progressViewStyle(.linear).frame(maxWidth: .infinity).padding(.horizontal) }
                Text("入力内容は povo の公式ページで処理されます。契約管理ではSIM再発行・解約等の手続きに進む場合があります。")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).padding() }
                if let url = WebPolicy.entry(page: context.page, token: context.token, deviceID: context.deviceID) {
                    AccountWebView(session: context, entry: url, repository: repository,
                                   onLoading: { loading = $0 }, onError: { error = $0 }, onDone: onDone)
                } else { ContentUnavailableView("安全に開ける公式URLがありません", systemImage: "lock.shield") }
            }
            .navigationTitle(context.page.kind.label).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる", action: onDone) } }
        }
    }
}

private struct AccountWebView: UIViewRepresentable {
    let session: WebSessionContext
    let entry: URL
    let repository: AccountRepository
    let onLoading: (Bool) -> Void
    let onError: (String) -> Void
    let onDone: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A different in-memory store for every account page. Never inherit a
        // previous account's cookies, localStorage or a 3DS session.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "povo")
        controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = view
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        // This port deliberately uses the reference adapter's Android web
        // contract, including its bridge selection. The engine remains WKWebKit;
        // no Android code or embedded browser engine is shipped.
        view.customUserAgent = "Mozilla/5.0 (Linux; Android 14; povo-ios) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile Safari/605.1.15"
        view.isInspectable = false
        view.load(URLRequest(url: entry))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.alive = false; uiView.stopLoading()
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
        uiView.configuration.userContentController.removeAllUserScripts()
        uiView.navigationDelegate = nil; uiView.uiDelegate = nil
    }
    private static let bridgeScript = #"""
    (() => {
      if (location.protocol !== 'https:' || !(location.hostname === 'povo.jp' || location.hostname.endsWith('.povo.jp'))) return;
      const nonce = String(Date.now()) + ':' + String(Math.random());
      Object.defineProperty(window, '__povoBridgeDocument', {value: nonce, configurable: false});
      const post = (body) => window.webkit.messageHandlers.povo.postMessage({...body, nonce});
      window.POVO_ANDROID_WEB_BRIDGE = Object.freeze({
        getAppVersion: () => JSON.stringify({app_version: '1.69.0'}),
        refreshXAuthToken: (callback, promiseId) => post({type: 'refresh', callback: String(callback), promiseId: String(promiseId)})
      });
      const notify = () => post({type: 'navigation', url: location.href});
      for (const method of ['pushState', 'replaceState']) {
        const original = history[method];
        history[method] = function(...args) { const result = original.apply(this, args); notify(); return result; };
      }
      window.addEventListener('popstate', notify);
      const installReferrerPolicy = () => {
        if (!document.head) return;
        const meta = document.createElement('meta'); meta.name = 'referrer'; meta.content = 'no-referrer';
        document.head.prepend(meta);
      };
      installReferrerPolicy(); document.addEventListener('DOMContentLoaded', installReferrerPolicy, {once:true});
    })();
    """#

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: AccountWebView
        weak var webView: WKWebView?
        var alive = true
        private var finished = false
        private var generation: UUID?
        init(parent: AccountWebView) { self.parent = parent; generation = parent.session.generation }
        private func trusted(_ origin: WKSecurityOrigin) -> Bool {
            guard origin.protocol.lowercased() == "https", origin.port == 0 || origin.port == 443 else { return false }
            let host = origin.host.lowercased()
            return host == "povo.jp" || host.hasSuffix(".povo.jp")
        }
        private func finish() { guard !finished else { return }; finished = true; parent.onDone() }
        private func inspect(_ url: URL) {
            if WebPolicy.matchesExit(url, path: parent.session.page.exitURL) { finish() }
            if WebPolicy.isSignedOut(url) { parent.onError("povo 側でログインが求められました。回線を再ログインして開き直すか、公式アプリをご利用ください。") }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let main = action.targetFrame?.isMainFrame ?? true
            if url.scheme?.lowercased() == "webfront" {
                if main, action.sourceFrame.isMainFrame, trusted(action.sourceFrame.securityOrigin),
                   let token = WebPolicy.rotatedToken(url), let generation, parent.session.page.needsXAuth {
                    Task {
                        do {
                            try await parent.repository.adoptWebToken(parent.session.accountID, token: token, generation: generation)
                            let session = try await parent.repository.webSession(parent.session.accountID)
                            guard alive, session.deviceID == parent.session.deviceID else { return }
                            self.generation = session.generation
                        } catch { if alive { parent.onError(AppFailure.describing(error).message) } }
                    }
                }
                decisionHandler(.cancel); return
            }
            if main, WebPolicy.matchesExit(url, path: parent.session.page.exitURL) { finish(); decisionHandler(.cancel); return }
            if let external = WebPolicy.externalURL(url), main {
                UIApplication.shared.open(external); decisionHandler(.cancel); return
            }
            if WebPolicy.isContact(url), main { UIApplication.shared.open(url); decisionHandler(.cancel); return }
            guard WebPolicy.isHTTPS(url) || url.absoluteString == "about:blank" else { decisionHandler(.cancel); return }
            if !WebPolicy.isPovo(url), let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               query.contains(where: { ["auth_token", "device_id"].contains($0.name.lowercased()) }) {
                parent.onError("認証情報を含む外部ページへの遷移を拒否しました"); decisionHandler(.cancel); return
            }
            if main { inspect(url) }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.onLoading(true) }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if let url = webView.url { inspect(url) } }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoading(false); if let url = webView.url { inspect(url) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onError("公式ページを読み込めませんでした。通信状態を確認して開き直してください。") }
            parent.onLoading(false)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoading(false); parent.onError("公式ページの読み込みに失敗しました")
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }; return nil
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard alive, message.frameInfo.isMainFrame, trusted(message.frameInfo.securityOrigin),
                  let current = webView?.url, WebPolicy.isPovo(current), let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            if type == "navigation", let text = body["url"] as? String, let url = URL(string: text), WebPolicy.isPovo(url) { inspect(url); return }
            guard type == "refresh", parent.session.page.needsXAuth, let expectedGeneration = generation,
                  let callback = body["callback"] as? String, WebPolicy.safeCallback(callback),
                  let promiseID = body["promiseId"] as? String, promiseID.count <= 1024,
                  let nonce = body["nonce"] as? String, nonce.count < 256 else { return }
            let origin = message.frameInfo.securityOrigin
            let expectedOrigin = "https://" + origin.host + (origin.port != 0 && origin.port != 443 ? ":\(origin.port)" : "")
            Task {
                do {
                    let session = try await parent.repository.webSession(parent.session.accountID)
                    guard alive, session.deviceID == parent.session.deviceID, session.generation == expectedGeneration,
                          let view = webView, let current = view.url, WebPolicy.isPovo(current) else { return }
                    let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["X-Auth": session.token]), as: UTF8.self)
                    // Both native origin checks AND a per-document JS nonce are
                    // required: navigation can occur while token refresh awaits.
                    let script = "if(location.origin===\(WebPolicy.quotedJS(expectedOrigin)) && window.__povoBridgeDocument===\(WebPolicy.quotedJS(nonce)) && typeof window[\(WebPolicy.quotedJS(callback))]==='function'){window[\(WebPolicy.quotedJS(callback))](\(WebPolicy.quotedJS(promiseID)),\(WebPolicy.quotedJS(payload)));}"
                    view.evaluateJavaScript(script, completionHandler: nil)
                } catch { if alive { parent.onError(AppFailure.describing(error).message) } }
            }
        }
    }
}
