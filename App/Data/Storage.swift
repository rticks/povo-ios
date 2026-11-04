import Foundation
import Security
import PovoKit

protocol SessionStorage: Sendable {
    func load() throws -> [PovoSession]
    func save(_ sessions: [PovoSession]) throws
}
protocol CacheStorage: Sendable {
    func load() throws -> AccountCache
    func save(_ cache: AccountCache) throws
}

final class KeychainSessionStorage: SessionStorage, @unchecked Sendable {
    private static let lock = NSLock()
    private let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "jp.povo.manager.ios") + ".sessions.v1") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "accounts", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> [PovoSession] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        do { return try JSONDecoder().decode([PovoSession].self, from: data) }
        catch { throw AppFailure("保存された認証情報を読み取れません。自動では削除しません。") }
    }
    func save(_ sessions: [PovoSession]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if sessions.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let data = try JSONEncoder().encode(sessions)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> AppFailure {
        if status == errSecInteractionNotAllowed {
            return AppFailure("端末のロックを一度解除すると認証情報を読み取れます")
        }
        return AppFailure("Keychain の読み書きに失敗しました（\(status)）。認証情報は削除していません。")
    }
}

final class FileCacheStorage: CacheStorage, @unchecked Sendable {
    private let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("povo", isDirectory: true).appendingPathComponent("accounts-v1.json")
    }
    func load() throws -> AccountCache {
        guard FileManager.default.fileExists(atPath: url.path) else { return AccountCache() }
        // This file is replaceable API cache, never credentials or hand input.
        guard let cache = try? JSONDecoder().decode(AccountCache.self, from: Data(contentsOf: url)),
              cache.schemaVersion == 1 else { return AccountCache() }
        return cache
    }
    func save(_ cache: AccountCache) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// No secrets: used for isolated tests and screenshot-only fixtures.
final class MemorySessionStorage: SessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [PovoSession]
    init(_ sessions: [PovoSession] = []) { self.sessions = sessions }
    func load() throws -> [PovoSession] { lock.lock(); defer { lock.unlock() }; return sessions }
    func save(_ sessions: [PovoSession]) throws { lock.lock(); defer { lock.unlock() }; self.sessions = sessions }
}
final class MemoryCacheStorage: CacheStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: AccountCache
    init(_ cache: AccountCache = AccountCache()) { self.cache = cache }
    func load() throws -> AccountCache { lock.lock(); defer { lock.unlock() }; return cache }
    func save(_ cache: AccountCache) throws { lock.lock(); defer { lock.unlock() }; self.cache = cache }
}
