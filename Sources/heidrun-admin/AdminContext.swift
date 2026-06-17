#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import ArgumentParser
import HeidrunServerKit

/// Global options shared by every subcommand. Resolves the same
/// `ServerConfiguration` the server uses (TOML via HEIDRUN_CONFIG + env),
/// then applies targeted CLI overrides.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the server's TOML config (else HEIDRUN_CONFIG).")
    var config: String?

    @Option(name: .long, help: "Override the accounts SQLite path.")
    var db: String?

    @Option(name: .long, help: "Override the news state JSON path.")
    var newsPath: String?

    @Option(name: .long, help: "Override the files root directory.")
    var filesRoot: String?

    /// Build the resolved configuration. CLI overrides win over file/env.
    func resolvedConfiguration() throws -> ServerConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let file: ServerConfigurationFile
        if let path = config ?? environment["HEIDRUN_CONFIG"] {
            file = try ServerConfigurationFile.load(from: path)
        } else {
            file = ServerConfigurationFile()
        }
        var configuration = file.resolved(environment: environment)
        if let db { configuration.accountStorePath = db }
        if let newsPath { configuration.newsStatePath = newsPath }
        if let filesRoot { configuration.filesRootPath = filesRoot }
        return configuration
    }

    func openAccountStore() throws -> AccountStore {
        let configuration = try resolvedConfiguration()
        return try AccountStore(
            path: configuration.accountStorePath,
            passwordRounds: configuration.passwordRounds
        )
    }

    func openAuditLog() throws -> AuditLog? {
        let configuration = try resolvedConfiguration()
        guard configuration.auditLogEnabled, configuration.auditDBPath != nil else { return nil }
        return try AuditLog(
            path: configuration.auditDBPath,
            retentionDays: configuration.auditRetentionDays
        )
    }
}

/// Terminal helpers (kept out of the Kit since they touch stdin/tty).
enum AdminIO {
    /// Read a password without echo (interactive), or from stdin when piped.
    static func readPassword(prompt: String) -> String {
        if let raw = getpass(prompt) { return String(cString: raw) }
        return ""
    }

    static func readPasswordFromStdin() -> String {
        (readLine(strippingNewline: true)) ?? ""
    }

    /// y/N confirmation read from the terminal. Returns false on EOF.
    static func confirm(_ message: String) -> Bool {
        FileHandle.standardError.write(Data("\(message) [y/N]: ".utf8))
        guard let answer = readLine(strippingNewline: true)?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }
}
