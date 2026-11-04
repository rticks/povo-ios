import Foundation
import Security
import PovoKit

/// Synchronous API, confined to an account's private DispatchQueue. No Rust
/// blocking call is made from the main actor or Swift cooperative executor.
protocol AccountService: AnyObject {
    var authToken: String? { get }
    var sin: String? { get }
    func refreshToken() throws -> String
    func profile() throws -> AccountProfile
    func usageJSON() throws -> String
    func billsJSON() throws -> String
    func quilt(_ page: String) throws -> String
    func order(sku: String) throws -> ToppingOrder
    func pdf(billID: String) throws -> Data
    func request(path: String, prefix: String?, version: String, body: String?) throws -> String
    func loginActions(email: String?, phone: String?) throws -> [ChallengeKind]
    func sendOTP(kind: ChallengeKind, email: String, phone: String) throws -> String
    func login(email: LoginChallenge?, mobile: LoginChallenge?) throws -> AuthResult
    func validatePIN(token: String, pin: String) throws -> AuthResult
}

typealias ServiceFactory = @Sendable (PovoSession) -> any AccountService

final class NativePovoService: AccountService {
    private let client: PovoClient
    init(deviceID: String, token: String? = nil, sin: String? = nil) {
        client = PovoClient(deviceId: deviceID, appVersion: WebPolicy.protocolVersion)
        // Preserve the reference adapter's tested wire contract. Merely changing
        // the host OS is not evidence that povo accepts different headers.
        client.setUserAgent(userAgent: "okhttp/4.12.0")
        if let token { client.setAuthToken(token: token) }
        if let sin { client.setServiceInstanceNumber(sin: sin) }
    }
    var authToken: String? { client.authToken() }
    var sin: String? { client.serviceInstanceNumber() }
    func refreshToken() throws -> String { try client.refreshToken().authToken }
    func profile() throws -> AccountProfile {
        let p = try client.getProfile()
        let telco = p.telcoInfo
        let birth: String? = p.dob.flatMap {
            guard let year = $0.year, let month = $0.month, let day = $0.day else { return nil }
            return CalendarDay(String(format: "%04d-%02d-%02d", year, month, day))?.description
        }
        return AccountProfile(externalID: p.externalId, email: p.email, phone: telco?.phoneNo,
                              name: telco?.customerName ?? p.firstName, sin: telco?.serviceInstanceNo,
                              planName: telco?.billingInfo?.planName, status: telco?.status,
                              activationDate: (telco?.activationDate ?? telco?.initialActivationDate)?.components(separatedBy: "T").first,
                              birthDate: birth)
    }
    func usageJSON() throws -> String { try client.getPlanUsageJson() }
    func billsJSON() throws -> String { try client.getJson(relativePath: "layout/bills/info", prefix: nil, version: "v5", locale: "ja") }
    func quilt(_ page: String) throws -> String { try client.getQuiltPageJson(page: page) }
    func order(sku: String) throws -> ToppingOrder {
        let body: [String: Any] = ["sku": sku, "offer_product": NSNull(), "redirect_url": WebPolicy.purchaseReturn.absoluteString]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let raw = try client.postJson(relativePath: "shop/orders", prefix: nil, version: "v2", locale: "ja", bodyJson:json)
        guard let result = QuiltParser.order(raw) else { throw AppFailure("購入結果を確認できません。再購入する前に購入履歴を確認してください。") }
        if let challenge = result.challengeURL, let url = URL(string: challenge), WebPolicy.isHTTPS(url) { return result }
        if result.needsChallenge { throw AppFailure("認証URLが安全なHTTPS URLではありません。購入履歴を確認してください。") }
        return result
    }
    func pdf(billID: String) throws -> Data { Data(try client.downloadBillPdf(billId: billID)) }
    func request(path: String, prefix: String?, version: String, body: String?) throws -> String {
        if let body {
            if path.hasPrefix("/") { return try client.postRawJson(absolutePath: path, bodyJson:body) }
            return try client.postJson(relativePath: path, prefix: prefix, version: version, locale: "ja", bodyJson:body)
        }
        if path.hasPrefix("/") { return try client.getRawJson(absolutePath: path) }
        return try client.getJson(relativePath: path, prefix: prefix, version: version, locale: "ja")
    }
    func loginActions(email: String?, phone: String?) throws -> [ChallengeKind] {
        try client.requestLoginAction(email: email, isdCode: phone == nil ? nil : "81", phoneNo: phone, captchaToken: nil).actions.map {
            switch $0.actionType {
            case .emailOtp: return .email
            case .loginOtp: return .sms
            case .registerOtp: return .register
            }
        }
    }
    func sendOTP(kind: ChallengeKind, email: String, phone: String) throws -> String {
        switch kind {
        case .email:
            guard email.nilIfBlank != nil else { throw AppFailure("メールアドレスを入力してください") }
            return try client.sendEmailOtp(email: email).authId
        case .sms, .register:
            guard phone.nilIfBlank != nil else { throw AppFailure("この認証ステップには電話番号が必要です") }
            return try client.sendMobileOtp(isdCode: "81", phoneNo: phone).authId
        }
    }
    func login(email: LoginChallenge?, mobile: LoginChallenge?) throws -> AuthResult {
        func native(_ c: LoginChallenge?) -> AuthChallenge? {
            c.map { AuthChallenge(authId: $0.authID, otpCode: $0.otp, deviceId: $0.deviceID) }
        }
        let result = try client.login(emailAuth: native(email), mobileAuth: native(mobile))
        return AuthResult(token: result.authToken, pinToken: result.pinToken)
    }
    func validatePIN(token: String, pin: String) throws -> AuthResult {
        let result = try client.validatePin(pinToken: token, pin: pin, captchaToken: nil)
        return AuthResult(token: result.authToken, pinToken: result.pinToken)
    }
}

extension AppFailure {
    static func describing(_ error: Error) -> AppFailure {
        if let e = error as? AppFailure { return e }
        if error is CancellationError { return AppFailure("処理を中止しました") }
        guard let e = error as? PovoError else { return AppFailure(DiagnosticRedactor.redact(error.localizedDescription)) }
        switch e {
        case .Unauthenticated: return AppFailure("再ログインが必要です", needsLogin: true)
        case .Network: return AppFailure("ネットワークに接続できません。最後に取得した情報を表示しています。")
        case .Decode: return AppFailure("povo の応答を読み取れません。最後に取得した情報を表示しています。")
        case .InvalidArgument: return AppFailure("入力が正しくありません")
        case let .Api(status, message, code, title, _, until):
            var pieces: [String] = []
            if status == 401 || status == 403 { pieces.append("再ログインが必要です") }
            if status == 429 { pieces.append("リクエストが多すぎます。しばらく待ってください") }
            if let message = message.nilIfBlank { pieces.append(String(DiagnosticRedactor.redact(message).prefix(160))) }
            if let code { pieces.append("コード \(code)") }
            if let title, title != message { pieces.append(String(DiagnosticRedactor.redact(title).prefix(80))) }
            pieces.append("HTTP \(status)")
            return AppFailure(pieces.joined(separator: " / "), needsLogin: status == 401 || status == 403,
                              blockedUntil: until.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }
}

enum DeviceIdentity {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppFailure("安全な端末IDを生成できませんでした")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
