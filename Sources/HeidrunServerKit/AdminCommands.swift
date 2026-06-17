import Foundation
import HeidrunCore

/// Errors surfaced by the admin command bodies. The executable maps these
/// to a stderr message + non-zero exit.
public enum AdminError: Swift.Error, Equatable {
    case accountNotFound(String)
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
}
