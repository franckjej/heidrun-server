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
        try Self.dropPrivilegesToDataOwnerIfRoot(dataPath: configuration.accountStorePath)
        return configuration
    }

    /// When invoked as root, drop to the owner of the accounts database so
    /// every file we touch or create (SQLite `-wal`/`-shm`, the news JSON,
    /// …) stays owned by the server's user instead of root — root-owned
    /// sidecar files would lock the container's user (e.g. UID 1979) out of
    /// its own database. This lets you just run `sudo heidrun-admin …` and
    /// have it act as the right user automatically.
    ///
    /// No-op when not root, or when the data is itself root-owned.
    /// Idempotent: once dropped, `geteuid()` is no longer 0.
    static func dropPrivilegesToDataOwnerIfRoot(dataPath: String?) throws {
        guard geteuid() == 0 else { return }
        guard let dataPath else { return }   // no DB path to anchor ownership on
        // The DB file's owner, or its parent dir's owner if the DB doesn't
        // exist yet (first-run create).
        let probe = FileManager.default.fileExists(atPath: dataPath)
            ? dataPath
            : (dataPath as NSString).deletingLastPathComponent
        var info = stat()
        guard stat(probe, &info) == 0 else {
            throw ValidationError("cannot stat \(probe) to choose a user to run as.")
        }
        let uid = info.st_uid
        let gid = info.st_gid
        guard uid != 0 else { return }   // data is root-owned → nothing to drop to
        // Order matters: supplementary groups, then gid, then uid (after
        // dropping uid you can no longer change gid).
        #if canImport(Glibc)
        _ = setgroups(0, nil)
        #endif
        guard setgid(gid) == 0, setuid(uid) == 0 else {
            throw ValidationError("failed to drop privileges to \(uid):\(gid).")
        }
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
