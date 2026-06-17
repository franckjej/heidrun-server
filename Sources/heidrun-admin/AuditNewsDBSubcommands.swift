import Foundation
import ArgumentParser
import HeidrunServerKit

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Query the audit log.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "transfer|auth|admin|presence, or a single kind.") var type: String?
    @Option(name: [.long, .customLong("account")], help: "Filter by account login.") var user: String?
    @Option(help: "Window: Nh, Nd, or a bare number of hours.") var since: String = "24h"
    @Option(help: "Max events.") var limit: Int = 200
    @Flag(help: "Emit JSON.") var json = false

    func run() async throws {
        guard let log = try global.openAuditLog() else {
            print("Audit log is disabled in this configuration."); return
        }
        var kinds: [AuditEvent.Kind]?
        if let type {
            guard let resolved = AuditQueryParsing.kinds(forTypeKeyword: type) else {
                throw ValidationError("Unknown --type '\(type)'.")
            }
            kinds = resolved
        }
        guard let hours = AuditQueryParsing.hours(fromSince: since) else {
            throw ValidationError("Bad --since '\(since)' (use Nh, Nd, or a number).")
        }
        let events = await AdminCommands.auditEvents(
            log: log, kinds: kinds, account: user, hours: hours, limit: limit)
        if json {
            print(try AdminFormat.json(events.map(AuditLineDTO.init)))
        } else {
            print(AdminFormat.auditTable(events))
        }
    }
}

/// Minimal JSON projection of an audit event for `--json`.
struct AuditLineDTO: Encodable {
    let timestamp: String
    let kind: String
    let account: String?
    let nickname: String?
    let target: String?
    let detail: String?
    init(_ event: AuditEvent) {
        self.timestamp = ISO8601DateFormatter().string(from: event.timestamp)
        self.kind = event.kind.rawValue
        self.account = event.account
        self.nickname = event.nickname
        self.target = event.target
        self.detail = event.detail
    }
}

struct News: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "News maintenance.", subcommands: [Reset.self])

    struct Reset: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "flat | threaded | all") var scope: String
        @Flag(name: .long, help: "Skip the confirmation prompt.") var yes = false
        func run() async throws {
            guard let resolved = NewsResetScope(parsing: scope) else {
                throw ValidationError("Unknown scope '\(scope)' (use flat, threaded, or all).")
            }
            let configuration = try global.resolvedConfiguration()
            let proceed = ConfirmationGate.shouldProceed(assumeYes: yes) {
                AdminIO.confirm("Wipe \(resolved.rawValue) news at \(configuration.newsStatePath ?? "(in-memory)")?")
            }
            guard proceed else { print("Aborted."); return }
            await AdminCommands.resetNews(path: configuration.newsStatePath, scope: resolved)
            print("News reset (\(resolved.rawValue)).")
        }
    }
}

struct DB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Database info.", subcommands: [Info.self])

    struct Info: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Flag(help: "Emit JSON.") var json = false
        func run() async throws {
            let configuration = try global.resolvedConfiguration()
            let store = try global.openAccountStore()
            let info = try await AdminCommands.dbInfo(store: store, configuration: configuration)
            if json {
                print(try AdminFormat.json(info))
            } else {
                print("""
                accounts:     \(info.accountCount)
                db path:      \(info.accountStorePath ?? "(in-memory)")
                audit db:     \(info.auditDBPath ?? "(in-memory)")  enabled=\(info.auditLogEnabled)
                news state:   \(info.newsStatePath ?? "(in-memory)")  mode=\(info.newsMode)
                files root:   \(info.filesRootPath ?? "(ephemeral temp)")
                """)
            }
        }
    }
}
