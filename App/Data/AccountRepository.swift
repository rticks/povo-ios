import Foundation
import PovoKit

private actor NetworkLimiter {
    private var available = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}

struct RefreshOutcome: Sendable {
    enum Status: Sendable, Equatable { case ok, failed, needsLogin, blocked, superseded }
    var accountID: String
    var status: Status
    var message: String?
}

actor AccountRepository {
    private let sessions: any SessionStorage
    private let cacheStorage: any CacheStorage
    private let factory: ServiceFactory
    private let limiter = NetworkLimiter()
    private var cache: AccountCache
    private struct PendingRefresh {
        var id: UUID
        var task: Task<RefreshOutcome, Never>
    }
    private var workers: [String: AccountWorker] = [:]
    private var inFlight: [String: PendingRefresh] = [:]
    private var ordersInFlight = Set<String>()

    init(sessions: any SessionStorage = KeychainSessionStorage(), cache: any CacheStorage = FileCacheStorage(),
         factory: @escaping ServiceFactory = { NativePovoService(deviceID: $0.deviceID, token: $0.authToken, sin: $0.sin) }) throws {
        self.sessions = sessions; cacheStorage = cache; self.factory = factory
        self.cache = try cache.load()
    }

    func snapshot() throws -> [AccountRecord] {
        let saved = try sessions.load()
        return saved.enumerated().map { index, session in
            cache.accounts.first(where: { $0.id == session.accountID }) ?? AccountRecord(
                id: session.accountID, profile: AccountProfile(externalID: session.externalID, email: session.email,
                                                              phone: session.phone, sin: session.sin), sortOrder: index)
        }.sorted { $0.sortOrder == $1.sortOrder ? $0.id < $1.id : $0.sortOrder < $1.sortOrder }
    }

    func register(token: String, deviceID: String, profile: AccountProfile, email: String?, phone: String?,
                  replacing accountID: String? = nil) throws -> String {
        let externalID = profile.externalID?.nilIfBlank ?? JWT.externalID(token)
        guard let id = externalID ?? email?.lowercased().nilIfBlank ?? phone?.nilIfBlank else {
            throw AppFailure("ログインしたアカウントの識別子を取得できませんでした")
        }
        if let accountID, accountID != id { throw AppFailure("別のアカウントでログインしました。元のアカウントは変更していません。") }
        let session = PovoSession(accountID: id, deviceID: deviceID, authToken: token, sin: profile.sin,
                                  email: profile.email ?? email, phone: profile.phone ?? phone,
                                  externalID: externalID, label: profile.phone ?? profile.email)
        var saved = try sessions.load()
        saved.removeAll { $0.accountID == id }; saved.append(session)
        try sessions.save(saved)
        workers.removeValue(forKey: id)
        inFlight.removeValue(forKey: id)?.task.cancel()
        var record = cache.accounts.first(where: { $0.id == id }) ?? AccountRecord(id: id, sortOrder: cache.accounts.count)
        record.profile = profile; record.lastError = nil; record.needsLogin = false; record.blockedUntil = nil
        put(record); try persistCache()
        return id
    }

    func remove(_ id: String) throws {
        var saved = try sessions.load(); saved.removeAll { $0.accountID == id }
        try sessions.save(saved) // credentials first; a late refresh cannot resurrect them
        workers.removeValue(forKey: id)
        inFlight.removeValue(forKey: id)?.task.cancel()
        cache.accounts.removeAll { $0.id == id }; try persistCache()
    }

    func refreshAll(policy: BillsPolicy = .ifStale) async -> [RefreshOutcome] {
        guard let saved = try? sessions.load() else { return [] }
        return await withTaskGroup(of: RefreshOutcome.self) { group in
            for session in saved {
                group.addTask { await self.refreshAccount(session.accountID, policy: policy) }
            }
            var result: [RefreshOutcome] = []
            for await outcome in group { result.append(outcome) }
            return result
        }
    }

    func refreshAccount(_ id: String, policy: BillsPolicy = .always) async -> RefreshOutcome {
        if let existing = inFlight[id] { return await existing.task.value }
        let requestID = UUID()
        let task = Task { await self.performRefresh(id, policy: policy) }
        inFlight[id] = PendingRefresh(id: requestID, task: task)
        let outcome = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        // A re-login can replace the entry while this task is awaiting I/O.
        // Only clear the old request, never a newer generation's task.
        if inFlight[id]?.id == requestID { inFlight.removeValue(forKey: id) }
        return outcome
    }

    private func performRefresh(_ id: String, policy: BillsPolicy) async -> RefreshOutcome {
        var expectedGeneration: UUID?
        do {
            let session = try session(id)
            expectedGeneration = session.generation
            let stored = cache.accounts.first { $0.id == id }
            if case .ifStale = policy, stored?.needsLogin == true {
                return RefreshOutcome(accountID: id, status: .needsLogin, message: stored?.lastError)
            }
            if let until = stored?.blockedUntil, until > Date() {
                return RefreshOutcome(accountID: id, status: .blocked, message: "povo の指定した待機時間中です")
            }
            let worker = worker(for: session)
            let includeBills = policy.wants(lastAttempt: stored?.billsAttemptedAt)
            let reply = try await limiter.run {
                try await Task.sleep(nanoseconds: UInt64.random(in: 0...250_000_000))
                return await worker.refresh(includeBills: includeBills)
            }
            guard try commit(reply) else { return RefreshOutcome(accountID: id, status: .superseded) }
            switch reply.result {
            case .success(let payload):
                var record = cache.accounts.first { $0.id == id } ?? AccountRecord(id: id, sortOrder: cache.accounts.count)
                record.profile = payload.profile
                record.usage = payload.usage; record.rawUsageJSON = payload.rawUsage
                record.usageFetchedAt = Date(); record.lastRefreshedAt = Date()
                if payload.billsAttempted { record.billsAttemptedAt = Date() }
                if let bills = payload.bills { record.bills = bills }
                if let toppings = payload.toppings { record.toppings = toppings }
                if let purchases = payload.purchases { record.purchases = purchases }
                if let info = payload.profileInfo { record.profileInfo = info }
                record.lastError = payload.warnings.isEmpty ? nil : payload.warnings.map(\.message).joined(separator: "\n")
                record.needsLogin = payload.warnings.contains(where: \.needsLogin)
                record.blockedUntil = payload.warnings.compactMap(\.blockedUntil).max()
                put(record)
                try updateMetadata(id: id, generation: reply.session.generation, profile: payload.profile)
                try persistCache()
                return RefreshOutcome(accountID: id, status: record.needsLogin ? .needsLogin : .ok, message: record.lastError)
            case .failure(let failure):
                try markFailure(id, failure)
                return RefreshOutcome(accountID: id, status: failure.needsLogin ? .needsLogin : .failed, message: failure.message)
            }
        } catch {
            if let expectedGeneration, (try? session(id).generation) != expectedGeneration {
                return RefreshOutcome(accountID: id, status: .superseded)
            }
            let failure = AppFailure.describing(error)
            if !(error is CancellationError) { try? markFailure(id, failure) }
            return RefreshOutcome(accountID: id, status: failure.needsLogin ? .needsLogin : .failed, message: failure.message)
        }
    }

    func catalogue(_ id: String) async throws -> [ToppingSection] {
        try await execute(id) { service in
            guard let result = QuiltParser.catalogue(try service.quilt("dashboard-v2")) else {
                throw AppFailure("トッピング一覧の応答を読み取れません")
            }
            return result
        }
    }
    func order(_ id: String, sku: String) async throws -> ToppingOrder {
        guard ordersInFlight.insert(id).inserted else { throw AppFailure("この回線の購入処理がすでに進行中です。結果を確認してください。") }
        defer { ordersInFlight.remove(id) }
        // There is intentionally no retry: a lost payment response is ambiguous.
        return try await execute(id) { try $0.order(sku: sku) }
    }
    func pdf(_ id: String, billID: String) async throws -> Data {
        try await execute(id) { try $0.pdf(billID: billID) }
    }
    func webSession(_ id: String) async throws -> (token: String, deviceID: String, generation: UUID) {
        let value: PovoSession = try await execute(id) { service in
            guard let token = service.authToken else { throw AppFailure("再ログインが必要です", needsLogin: true) }
            return PovoSession(accountID: id, deviceID: "", authToken: token)
        }
        let current = try session(id)
        // Never return a fresh token with another generation's device id.
        guard current.authToken == value.authToken else { throw AppFailure("認証情報が変更されました。開き直してください。") }
        return (current.authToken, current.deviceID, current.generation)
    }
    func adoptWebToken(_ id: String, token: String, generation: UUID) throws {
        var saved = try sessions.load()
        guard let index = saved.firstIndex(where: { $0.accountID == id && $0.generation == generation }),
              JWT.externalID(token) == (saved[index].externalID ?? JWT.externalID(saved[index].authToken)),
              JWT.expiresAt(token) != nil else { throw AppFailure("Web画面の認証情報が現在のアカウントと一致しません") }
        guard saved[index].authToken != token else { return }
        saved[index].authToken = token; saved[index].generation = UUID()
        try sessions.save(saved); workers.removeValue(forKey: id)
    }
    #if DEBUG
    func diagnostic(_ id: String, path: String, prefix: String?, version: String, body: String?) async throws -> String {
        let raw: String = try await execute(id) { try $0.request(path: path, prefix: prefix, version: version, body: body) }
        return DiagnosticRedactor.redact(raw)
    }
    #endif

    private func execute<T: Sendable>(_ id: String, _ operation: @escaping @Sendable (any AccountService) throws -> T) async throws -> T {
        let session = try session(id)
        if let until = cache.accounts.first(where: { $0.id == id })?.blockedUntil, until > Date() {
            throw AppFailure("povo の指定した待機時間中です", blockedUntil: until)
        }
        let worker = worker(for: session)
        let reply = try await limiter.run { await worker.perform(operation) }
        guard try commit(reply) else { throw AppFailure("アカウントの認証情報が変更されました。もう一度開いてください。") }
        do { return try reply.result.get() }
        catch {
            let failure = AppFailure.describing(error)
            try? markFailure(id, failure)
            throw failure
        }
    }
    private func session(_ id: String) throws -> PovoSession {
        guard let session = try sessions.load().first(where: { $0.accountID == id }) else { throw AppFailure("アカウントが見つかりません") }
        return session
    }
    private func worker(for session: PovoSession) -> AccountWorker {
        if let existing = workers[session.accountID], existing.deviceID == session.deviceID, existing.generation == session.generation { return existing }
        let created = AccountWorker(session: session, factory: factory)
        workers[session.accountID] = created
        return created
    }
    private func commit<T>(_ reply: WorkerReply<T>) throws -> Bool {
        var saved = try sessions.load()
        guard let index = saved.firstIndex(where: { $0.accountID == reply.session.accountID }),
              saved[index].deviceID == reply.session.deviceID, saved[index].generation == reply.session.generation,
              saved[index].authToken == reply.startingToken || saved[index].authToken == reply.session.authToken else { return false }
        saved[index].authToken = reply.session.authToken
        saved[index].sin = reply.session.sin ?? saved[index].sin
        try sessions.save(saved)
        return true
    }
    private func updateMetadata(id: String, generation: UUID, profile: AccountProfile) throws {
        var saved = try sessions.load()
        guard let index = saved.firstIndex(where: { $0.accountID == id && $0.generation == generation }) else { return }
        saved[index].sin = profile.sin ?? saved[index].sin
        saved[index].email = profile.email ?? saved[index].email
        saved[index].phone = profile.phone ?? saved[index].phone
        saved[index].label = profile.phone ?? profile.email ?? saved[index].label
        try sessions.save(saved)
    }
    private func put(_ record: AccountRecord) {
        cache.accounts.removeAll { $0.id == record.id }; cache.accounts.append(record)
    }
    private func markFailure(_ id: String, _ failure: AppFailure) throws {
        guard (try? session(id)) != nil else { return }
        var record = cache.accounts.first { $0.id == id } ?? AccountRecord(id: id)
        record.lastError = failure.message; record.needsLogin = failure.needsLogin
        record.blockedUntil = failure.blockedUntil
        put(record); try persistCache()
    }
    private func persistCache() throws { try cacheStorage.save(cache) }
}
