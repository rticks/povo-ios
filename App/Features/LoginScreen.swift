import SwiftUI
import PovoKit

@MainActor
final class LoginViewModel: ObservableObject {
    enum Step { case identifier, otp, pin, done }
    @Published var step: Step = .identifier
    @Published var email = ""
    @Published var phone = ""
    @Published var useSMS = false
    @Published var otp = ""
    @Published var pin = ""
    @Published var busy = false
    @Published var error: String?
    @Published var pending: [ChallengeKind] = []
    @Published var addedAccountID: String?
    @Published var resendAfter = Date.distantPast
    @Published private(set) var hasSentCode = false
    private var worker: LoginWorker?
    private var authID: String?
    private var answers: [(ChallengeKind, LoginChallenge)] = []
    private var pinToken: String?
    private var task: Task<Void, Never>?
    init() { makeWorker() }
    private func makeWorker() {
        do { worker = try LoginWorker() }
        catch { self.error = AppFailure.describing(error).message }
    }
    func start() {
        run {
            guard let worker = self.worker else { throw AppFailure("認証を初期化できません。最初からやり直してください。") }
            let email = self.email.nilIfBlank
            let phone = self.phone.nilIfBlank
            guard self.useSMS ? phone != nil : email != nil else { throw AppFailure("ログインに使う識別子を入力してください") }
            var actions = try await worker.perform { try $0.loginActions(email: email, phone: phone) }
            if actions.isEmpty { actions = [self.useSMS ? .sms : .email] }
            self.pending = actions; self.answers = []; self.step = .otp
            try await self.sendCurrent()
        }
    }
    func resend() { run { try await self.sendCurrent() } }
    private func sendCurrent() async throws {
        guard Date() >= resendAfter, let action = pending.first, let worker else { return }
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = self.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let authID = try await worker.perform { try $0.sendOTP(kind: action, email: email, phone: phone) }
        try Task.checkCancellation()
        self.authID = authID; hasSentCode = true; otp = ""; resendAfter = Date(timeIntervalSinceNow: 60)
    }
    func submit(repository: AccountRepository, replacing id: String?) {
        run {
            guard let action = self.pending.first, let authID = self.authID, let worker = self.worker else {
                throw AppFailure("先に認証コードを送信してください")
            }
            guard let code = self.otp.nilIfBlank else { throw AppFailure("認証コードを入力してください") }
            let challenge = LoginChallenge(authID: authID, otp: code, deviceID: worker.deviceID)
            self.answers.removeAll { $0.0 == action }; self.answers.append((action, challenge))
            if self.pending.count > 1 {
                // Commit the next step only after it has a code. If sending
                // fails, keep a recoverable step instead of losing the wizard.
                self.pending.removeFirst(); self.authID = nil; self.hasSentCode = false
                self.resendAfter = .distantPast
                try await self.sendCurrent(); return
            }
            let emailAuth = self.answers.last(where: { $0.0 == .email })?.1
            let mobileAuth = self.answers.last(where: { $0.0 != .email })?.1
            let result = try await worker.perform { try $0.login(email: emailAuth, mobile: mobileAuth) }
            try Task.checkCancellation()
            if let pinToken = result.pinToken {
                self.pinToken = pinToken; self.step = .pin; return
            }
            try await self.complete(result, repository: repository, replacing: id)
        }
    }
    func submitPIN(repository: AccountRepository, replacing id: String?) {
        run {
            guard let pinToken = self.pinToken, let worker = self.worker, let pin = self.pin.nilIfBlank else { throw AppFailure("PINを入力してください") }
            let result = try await worker.perform { try $0.validatePIN(token: pinToken, pin: pin) }
            try Task.checkCancellation()
            guard result.pinToken == nil else { throw AppFailure("追加のPIN認証が必要です。公式アプリをご利用ください。") }
            try await self.complete(result, repository: repository, replacing: id)
        }
    }
    private func complete(_ result: AuthResult, repository: AccountRepository, replacing id: String?) async throws {
        guard let worker else { throw AppFailure("認証が初期化されていません") }
        let profile = try await worker.perform { try $0.profile() }
        try Task.checkCancellation()
        let accountID = try await repository.register(token: result.token, deviceID: worker.deviceID, profile: profile,
                                                      email: email.nilIfBlank, phone: phone.nilIfBlank, replacing: id)
        self.addedAccountID = accountID; self.step = .done
        otp = ""; pin = ""; answers = []; pinToken = nil
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false }
            do { try await operation() }
            catch is CancellationError { }
            catch { self.error = AppFailure.describing(error).message }
        }
    }
    func restart() {
        task?.cancel(); worker = nil; answers = []; authID = nil; pinToken = nil
        pending = []; otp = ""; pin = ""; error = nil; step = .identifier
        resendAfter = .distantPast; hasSentCode = false; busy = false; makeWorker()
    }
    func cancel() { task?.cancel() }
}

struct LoginScreen: View {
    var replacing: String? = nil
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = LoginViewModel()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(replacing == nil ? "アカウントを追加" : "アカウントを再認証", systemImage: "person.crop.circle.badge.plus")
                        .font(.title2.weight(.semibold)).padding(.vertical, 12)
                    Text("povo に登録したメールアドレスまたは電話番号でログインします。パスワードは保存せず、認証情報はこの端末の Keychain だけに保存します。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if vm.step == .identifier {
                    Section("ログイン方法") {
                        Picker("ログイン方法", selection: $vm.useSMS) {
                            Text("メール").tag(false); Text("SMS").tag(true)
                        }.pickerStyle(.segmented)
                        if !vm.useSMS { emailField }
                        else { phoneField }
                        Button("認証コードを送信") { vm.start() }
                            .disabled(vm.busy || (vm.useSMS ? vm.phone.nilIfBlank == nil : vm.email.nilIfBlank == nil))
                            .accessibilityIdentifier("send-otp")
                    }
                } else if vm.step == .otp {
                    Section(vm.pending.first == .email ? "メールの認証コード" : "SMSの認証コード") {
                        if vm.pending.first == .email { emailField }
                        else { phoneField }
                        if vm.hasSentCode {
                            TextField("認証コード", text: $vm.otp).keyboardType(.numberPad).textContentType(.oneTimeCode)
                                .accessibilityIdentifier("otp-code")
                            Button("認証して進む") { vm.submit(repository: model.repository, replacing: replacing) }
                                .disabled(vm.busy || vm.otp.nilIfBlank == nil)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(ceil(vm.resendAfter.timeIntervalSince(context.date))))
                            Button(remaining > 0 ? "再送信まで \(remaining) 秒" : (vm.hasSentCode ? "コードを再送信" : "コードを送信")) { vm.resend() }
                                .disabled(vm.busy || remaining > 0)
                        }
                    } footer: { Text("povo が要求する認証を順に処理します。複数のコードが必要な場合も、最後まで同じ端末IDを使用します。") }
                } else if vm.step == .pin {
                    Section("追加のPIN認証") {
                        SecureField("PIN", text: $vm.pin).keyboardType(.numberPad)
                        Text("この追加認証は参照コアに実装されていますが、実アカウントでは未検証です。失敗する場合は公式アプリをご利用ください。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("PINを確認") { vm.submitPIN(repository: model.repository, replacing: replacing) }.disabled(vm.busy || vm.pin.isEmpty)
                    }
                }
                if vm.busy { Section { HStack { ProgressView(); Text("povo と通信中…") } } }
                if let error = vm.error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                if vm.step != .identifier {
                    Section { Button("最初からやり直す") { vm.restart() }.disabled(vm.busy) }
                }
                Section { Text("非公式クライアントです。KDDI / povo / Circles.life とは関係ありません。ご自身が管理するアカウントだけを登録してください。")
                        .font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("ログイン").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { vm.cancel(); dismiss() } } }
            .onChange(of: vm.addedAccountID) { _, id in
                guard let id else { return }
                Task { await model.reload(); await model.refresh(id) }
                dismiss()
            }
            .onDisappear { vm.cancel() }
        }
    }
    private var emailField: some View {
        TextField("メールアドレス", text: $vm.email).keyboardType(.emailAddress).textContentType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(vm.busy)
            .accessibilityIdentifier("login-email")
    }
    private var phoneField: some View {
        TextField("電話番号", text: $vm.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
            .disabled(vm.busy).accessibilityIdentifier("login-phone")
    }
}
