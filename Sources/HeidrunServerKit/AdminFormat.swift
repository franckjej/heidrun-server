import Foundation
import HeidrunCore

/// Pure rendering for the admin CLI. Two modes: a human table/lines, or
/// `--json`. Never emits the stored password hash.
public enum AdminFormat {

    /// JSON-safe projection of an account (no password hash).
    public struct AccountDTO: Codable, Equatable, Sendable {
        public var login: String
        public var nickname: String
        public var iconID: UInt16
        public var permissions: UInt64
        public var privileges: [String]
        public var createdAt: Date
        public var updatedAt: Date
    }

    public static func accountDTO(_ account: Account) -> AccountDTO {
        AccountDTO(
            login: account.login,
            nickname: account.nickname,
            iconID: account.iconID,
            permissions: account.permissions,
            privileges: PrivilegeNames.names(in: UserPrivileges(rawValue: account.permissions)),
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }

    /// Encode any Encodable to pretty JSON with ISO-8601 dates and stable
    /// key ordering (so output is diffable / testable).
    public static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    /// One line per account: login, nickname, admin marker.
    public static func accountTable(_ accounts: [Account]) -> String {
        if accounts.isEmpty { return "No accounts." }
        let header = "LOGIN                NICKNAME             ADMIN"
        let rows = accounts.map { account in
            let login = account.login.padding(toLength: 20, withPad: " ", startingAt: 0)
            let nick = account.nickname.padding(toLength: 20, withPad: " ", startingAt: 0)
            return "\(login) \(nick) \(account.isAdmin ? "yes" : "no")"
        }
        return ([header] + rows).joined(separator: "\n")
    }

    /// Multi-line detail for a single account, including its privilege names.
    public static func accountDetail(_ account: Account) -> String {
        let privileges = PrivilegeNames.names(in: UserPrivileges(rawValue: account.permissions))
        let privList = privileges.isEmpty ? "(none)" : privileges.joined(separator: ", ")
        return """
        login:       \(account.login)
        nickname:    \(account.nickname)
        iconID:      \(account.iconID)
        admin:       \(account.isAdmin ? "yes" : "no")
        privileges:  \(privList)
        created:     \(account.createdAt)
        updated:     \(account.updatedAt)
        """
    }

    /// One line per audit event, oldest first.
    public static func auditTable(_ events: [AuditEvent]) -> String {
        if events.isEmpty { return "No matching audit events." }
        return events.map { event in
            let kind = event.kind.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)
            let who = (event.account ?? event.nickname ?? "—")
            let target = event.target.map { " → \($0)" } ?? ""
            return "\(event.timestamp)  \(kind)  \(who)\(target)"
        }.joined(separator: "\n")
    }
}
