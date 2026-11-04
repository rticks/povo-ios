import Foundation

public struct PovoSession: Codable, Equatable, Sendable {
    public var accountID: String
    public var deviceID: String
    public var authToken: String
    public var sin: String?
    public var email: String?
    public var phone: String?
    public var externalID: String?
    public var label: String?
    /// Re-login and web token rotation start a new generation. Results from an
    /// older generation cannot overwrite the new device/token pair.
    public var generation: UUID
    public init(accountID: String, deviceID: String, authToken: String, sin: String? = nil,
                email: String? = nil, phone: String? = nil, externalID: String? = nil,
                label: String? = nil, generation: UUID = UUID()) {
        self.accountID = accountID; self.deviceID = deviceID; self.authToken = authToken
        self.sin = sin; self.email = email; self.phone = phone; self.externalID = externalID
        self.label = label; self.generation = generation
    }
}

public struct AccountProfile: Codable, Equatable, Sendable {
    public var externalID: String?
    public var email: String?
    public var phone: String?
    public var name: String?
    public var sin: String?
    public var planName: String?
    public var status: String?
    public var activationDate: String?
    public var birthDate: String?
    public init(externalID: String? = nil, email: String? = nil, phone: String? = nil,
                name: String? = nil, sin: String? = nil, planName: String? = nil,
                status: String? = nil, activationDate: String? = nil, birthDate: String? = nil) {
        self.externalID = externalID; self.email = email; self.phone = phone; self.name = name
        self.sin = sin; self.planName = planName; self.status = status
        self.activationDate = activationDate; self.birthDate = birthDate
    }
}

public struct AccountRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var profile: AccountProfile
    public var usage: PlanUsage?
    public var usageFetchedAt: Date?
    public var rawUsageJSON: String?
    public var bills: BillsDocument?
    public var billsAttemptedAt: Date?
    public var toppings: [Topping] = []
    public var purchases: [Purchase] = []
    public var profileInfo: ProfileInfo?
    public var lastRefreshedAt: Date?
    public var lastError: String?
    public var needsLogin = false
    public var blockedUntil: Date?
    public var sortOrder: Int = 0
    public var label: String { profile.phone ?? profile.email ?? id }
    public init(id: String, profile: AccountProfile = AccountProfile(), sortOrder: Int = 0) {
        self.id = id; self.profile = profile; self.sortOrder = sortOrder
    }
}

public struct AccountCache: Codable, Sendable {
    public var schemaVersion = 1
    public var accounts: [AccountRecord] = []
    public init(accounts: [AccountRecord] = []) { self.accounts = accounts }
}

public struct AppFailure: Error, LocalizedError, Equatable, Sendable {
    public var message: String
    public var needsLogin: Bool
    public var blockedUntil: Date?
    public init(_ message: String, needsLogin: Bool = false, blockedUntil: Date? = nil) {
        self.message = message; self.needsLogin = needsLogin; self.blockedUntil = blockedUntil
    }
    public var errorDescription: String? { message }
}

public enum ChallengeKind: String, Codable, Sendable { case email, sms, register }
public struct LoginChallenge: Sendable, Equatable {
    public var authID: String
    public var otp: String
    public var deviceID: String
    public init(authID: String, otp: String, deviceID: String) { self.authID = authID; self.otp = otp; self.deviceID = deviceID }
}
public struct AuthResult: Sendable {
    public var token: String
    public var pinToken: String?
    public init(token: String, pinToken: String? = nil) { self.token = token; self.pinToken = pinToken }
}

/// Minimal, credential-free export shared with the WidgetKit extension.
public struct WidgetAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var leftKB: Double?
    public var usedKB: Double?
    public var fetchedAt: Date?
    public var needsLogin: Bool
    public var remaining: String { leftKB.map(PlanUsage.formatKB) ?? "未取得" }
    public var fraction: Double? {
        guard let leftKB, let usedKB, leftKB.isFinite, usedKB.isFinite, leftKB + usedKB > 0 else { return nil }
        return min(1, max(0, leftKB / (leftKB + usedKB)))
    }
    public init(record: AccountRecord) {
        id = record.id; label = record.label; leftKB = record.usage?.totalLeftKB
        usedKB = record.usage?.totalUsedKB; fetchedAt = record.usageFetchedAt; needsLogin = record.needsLogin
    }
}
public struct WidgetSnapshot: Codable, Sendable {
    public var accounts: [WidgetAccount]
    public var updatedAt: Date
    public init(accounts: [WidgetAccount] = [], updatedAt: Date = Date()) {
        self.accounts = accounts; self.updatedAt = updatedAt
    }
}

public enum ThemeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, light, dark, povo
    public var id: Self { self }
    public var label: String {
        switch self {
        case .system: return "システム"
        case .light: return "ライト"
        case .dark: return "ダーク"
        case .povo: return "povo カラー"
        }
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var theme: ThemeMode = .system
    public var backgroundRefresh = true
    public var suspensionEnabled = true
    public var notifySuspension = false
    public var notifyDays = 14
    public var shareWithWidgets = true
    public init() {}
}
