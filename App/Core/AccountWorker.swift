import Foundation
import PovoKit

struct WorkerReply<Value: Sendable>: Sendable {
    var session: PovoSession
    var startingToken: String
    var result: Result<Value, AppFailure>
}

struct RefreshPayload: Sendable {
    var profile: AccountProfile
    var usage: PlanUsage
    var rawUsage: String
    var bills: BillsDocument?
    var toppings: [Topping]?
    var purchases: [Purchase]?
    var profileInfo: ProfileInfo?
    var billsAttempted: Bool
    var warnings: [AppFailure]
}

/// @unchecked is limited to queue confinement: service/session are never touched
/// outside this private serial queue. Accounts have separate queues and objects.
final class AccountWorker: @unchecked Sendable {
    let deviceID: String
    let generation: UUID
    private let queue: DispatchQueue
    private let service: any AccountService
    private var session: PovoSession
    init(session: PovoSession, factory: ServiceFactory) {
        self.session = session; deviceID = session.deviceID; generation = session.generation
        queue = DispatchQueue(label: "jp.povo.manager.account.\(UUID().uuidString)", qos: .utility)
        service = factory(session)
    }
    func perform<Value: Sendable>(_ operation: @escaping @Sendable (any AccountService) throws -> Value) async -> WorkerReply<Value> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let startingToken = session.authToken
                let result: Result<Value, AppFailure>
                do {
                    if JWT.isExpired(service.authToken ?? session.authToken) { _ = try service.refreshToken() }
                    result = .success(try operation(service))
                } catch { result = .failure(.describing(error)) }
                // Even if a later endpoint fails, do not lose a successful token
                // renewal. The repository uses a generation/token CAS to commit.
                session.authToken = service.authToken ?? session.authToken
                session.sin = service.sin ?? session.sin
                continuation.resume(returning: WorkerReply(session: session, startingToken: startingToken, result: result))
            }
        }
    }
    func refresh(includeBills: Bool) async -> WorkerReply<RefreshPayload> {
        await perform { service in
            let profile = try service.profile() // discovers SIN before any account GET
            let raw = try service.usageJSON()
            guard let usage = UsageParser.parse(raw) else { throw AppFailure("残量の形式が変わったため更新できません。最後の取得値を保持しています。") }
            var warnings: [AppFailure] = []
            func optional<T>(_ operation: () throws -> T?) -> T? {
                do {
                    guard let value = try operation() else {
                        warnings.append(AppFailure("一部の応答を読み取れませんでした。前回の情報を保持しています。"))
                        return nil
                    }
                    return value
                } catch { warnings.append(.describing(error)); return nil }
            }
            let toppings = optional { QuiltParser.toppings(try service.quilt("user-plan-details-v2")) }
            let bills = includeBills ? optional { BillsParser.parse(try service.billsJSON()) } : nil
            let purchases = includeBills ? optional { QuiltParser.purchases(try service.quilt("order-history")) } : nil
            let profileInfo = includeBills ? optional { QuiltParser.profile(try service.quilt("profile")) } : nil
            return RefreshPayload(profile: profile, usage: usage, rawUsage: raw, bills: bills, toppings: toppings,
                                  purchases: purchases, profileInfo: profileInfo, billsAttempted: includeBills, warnings: warnings)
        }
    }
}

/// A pending login gets its own device id/client, never one borrowed from an
/// already authenticated account. All OTPs use that same device id.
final class LoginWorker: @unchecked Sendable {
    let deviceID: String
    private let service: any AccountService
    private let queue = DispatchQueue(label: "jp.povo.manager.login", qos: .userInitiated)
    init() throws {
        deviceID = try DeviceIdentity.generate()
        service = NativePovoService(deviceID: deviceID)
    }
    func perform<Value: Sendable>(_ operation: @escaping @Sendable (any AccountService) throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try operation(service)) }
                catch { continuation.resume(throwing: AppFailure.describing(error)) }
            }
        }
    }
}
