import Foundation
import HeidrunCore

/// Errors surfaced by the admin command bodies. The executable maps these
/// to a stderr message + non-zero exit.
public enum AdminError: Swift.Error, Equatable, LocalizedError {
    case accountNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .accountNotFound(let login): return "Account not found: \(login)"
        }
    }
}

/// Testable bodies behind the `heidrun-admin` CLI. Pure logic over the
/// stores — no argument parsing, no I/O prompting, no rendering.
public enum AdminCommands {

    // MARK: - Accounts

    @discardableResult
    public static func create(
        store: AccountStore, login: String, password: String,
        nickname: String?, permissions: UInt64
    ) async throws -> Account {
        try await store.create(
            login: login, password: password,
            nickname: nickname ?? login, permissions: permissions
        )
    }

    public static func list(store: AccountStore) async throws -> [Account] {
        try await store.list()
    }

    public static func show(store: AccountStore, login: String) async throws -> Account {
        guard let account = try await store.get(login: login) else {
            throw AdminError.accountNotFound(login)
        }
        return account
    }

    @discardableResult
    public static func setPassword(
        store: AccountStore, login: String, newPassword: String
    ) async throws -> Account {
        guard let updated = try await store.update(
            login: login, nickname: nil, iconID: nil,
            permissions: nil, newPassword: newPassword
        ) else { throw AdminError.accountNotFound(login) }
        return updated
    }

    @discardableResult
    public static func rename(
        store: AccountStore, login: String, nickname: String
    ) async throws -> Account {
        guard let updated = try await store.update(
            login: login, nickname: nickname, iconID: nil,
            permissions: nil, newPassword: nil
        ) else { throw AdminError.accountNotFound(login) }
        return updated
    }

    @discardableResult
    public static func delete(store: AccountStore, login: String) async throws -> Bool {
        try await store.delete(login: login)
    }

    /// Apply privilege edits. When `set` is non-nil it replaces the whole
    /// mask; otherwise the result is `(current | grant) & ~revoke`.
    @discardableResult
    public static func editPrivileges(
        store: AccountStore, login: String,
        grant: UserPrivileges, revoke: UserPrivileges, set: UserPrivileges?
    ) async throws -> Account {
        guard let current = try await store.get(login: login) else {
            throw AdminError.accountNotFound(login)
        }
        let newMask: UserPrivileges
        if let set {
            newMask = set
        } else {
            var working = UserPrivileges(rawValue: current.permissions)
            working.formUnion(grant)
            working.subtract(revoke)
            newMask = working
        }
        guard let updated = try await store.update(
            login: login, nickname: nil, iconID: nil,
            permissions: newMask.rawValue, newPassword: nil
        ) else { throw AdminError.accountNotFound(login) }
        return updated
    }

    // MARK: - Audit

    /// Offline audit query — thin pass-through to `AuditLog.query`, oldest
    /// first. The executable resolves `kinds`/`hours` via `AuditQueryParsing`.
    public static func auditEvents(
        log: AuditLog, kinds: [AuditEvent.Kind]?, account: String?,
        hours: Int, limit: Int
    ) async -> [AuditEvent] {
        await log.query(type: kinds, account: account, withinHours: hours, limit: limit)
    }

    // MARK: - News

    /// One-shot wipe of the selected news store(s) at `path`, persisting the
    /// empty snapshot. No-op (in-memory only) when `path` is nil.
    public static func resetNews(path: String?, scope: NewsResetScope) async {
        let tree = NewsTree(persistencePath: path)
        await tree.reset(scope)
    }

    // MARK: - DB info

    public struct DBInfo: Sendable, Codable, Equatable {
        public var accountCount: Int
        public var accountStorePath: String?
        public var auditDBPath: String?
        public var auditLogEnabled: Bool
        public var newsStatePath: String?
        public var newsMode: String
        public var filesRootPath: String?
    }

    public static func dbInfo(
        store: AccountStore, configuration: ServerConfiguration
    ) async throws -> DBInfo {
        DBInfo(
            accountCount: try await store.count(),
            accountStorePath: configuration.accountStorePath,
            auditDBPath: configuration.auditDBPath,
            auditLogEnabled: configuration.auditLogEnabled,
            newsStatePath: configuration.newsStatePath,
            newsMode: configuration.newsMode.rawValue,
            filesRootPath: configuration.filesRootPath
        )
    }
}
