import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("ServerConfigurationFile")
struct ServerConfigurationFileTests {
    private func writeTOML(_ content: String) throws -> String {
        let path = NSTemporaryDirectory()
            + "HeidrunServer-Config-\(UUID().uuidString).toml"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("load parses a populated TOML file")
    func parsesPopulatedTOML() throws {
        let path = try writeTOML(#"""
        port = 5500
        server_name = "Heidrun"
        log_level = "debug"
        agreement = "Welcome."
        db_path = "/var/lib/heidrun/heidrun.sqlite"
        files_root = "/var/lib/heidrun/files"

        [bootstrap_admin]
        login = "root"
        password = "s3cret"
        nickname = "Root"
        """#)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let file = try ServerConfigurationFile.load(from: path)
        #expect(file.port == 5500)
        #expect(file.serverName == "Heidrun")
        #expect(file.logLevel == "debug")
        #expect(file.agreement == "Welcome.")
        #expect(file.dbPath == "/var/lib/heidrun/heidrun.sqlite")
        #expect(file.filesRoot == "/var/lib/heidrun/files")
        #expect(file.bootstrapAdmin?.login == "root")
        #expect(file.bootstrapAdmin?.password == "s3cret")
    }

    @Test("news_mode defaults to threaded with the full advertised version")
    func newsModeDefaultsThreaded() {
        let config = ServerConfigurationFile().resolved(environment: [:])
        #expect(config.newsMode == .threaded)
        #expect(config.effectiveAdvertisedVersion == 185)
    }

    @Test("news_mode = flat caps the advertised version below Hotline 1.5")
    func newsModeFlatCapsVersion() {
        var file = ServerConfigurationFile()
        file.newsMode = "flat"
        let config = file.resolved(environment: [:])
        #expect(config.newsMode == .flat)
        #expect(config.effectiveAdvertisedVersion <= 150)
    }

    @Test("HEIDRUN_NEWS_MODE overrides the file; unknown values fall back to threaded")
    func newsModeEnvOverride() {
        var file = ServerConfigurationFile()
        file.newsMode = "threaded"
        #expect(file.resolved(environment: ["HEIDRUN_NEWS_MODE": "flat"]).newsMode == .flat)
        #expect(file.resolved(environment: ["HEIDRUN_NEWS_MODE": "plain"]).newsMode == .flat)
        #expect(ServerConfigurationFile().resolved(environment: ["HEIDRUN_NEWS_MODE": "bogus"]).newsMode == .threaded)
    }

    @Test("news_reset defaults to nil; file + env parse flat/threaded/all with aliases")
    func newsResetResolution() {
        // Unset → no reset.
        #expect(ServerConfigurationFile().resolved(environment: [:]).newsReset == nil)
        // TOML key.
        var file = ServerConfigurationFile()
        file.newsReset = "flat"
        #expect(file.resolved(environment: [:]).newsReset == .flat)
        // Env overrides the file; aliases resolve.
        #expect(file.resolved(environment: ["HEIDRUN_NEWS_RESET": "all"]).newsReset == .all)
        #expect(file.resolved(environment: ["HEIDRUN_NEWS_RESET": "both"]).newsReset == .all)
        #expect(file.resolved(environment: ["HEIDRUN_NEWS_RESET": "plain"]).newsReset == .flat)
        #expect(file.resolved(environment: ["HEIDRUN_NEWS_RESET": "threaded"]).newsReset == .threaded)
        // Unknown value → nil (no accidental wipe).
        #expect(ServerConfigurationFile().resolved(environment: ["HEIDRUN_NEWS_RESET": "bogus"]).newsReset == nil)
    }

    @Test("load returns LoadError.unreadable for a missing file")
    func unreadableOnMissingFile() {
        do {
            _ = try ServerConfigurationFile.load(from: "/nope/nope.toml")
            #expect(Bool(false), "expected throw")
        } catch let error as ServerConfigurationFile.LoadError {
            if case .unreadable(let badPath) = error {
                #expect(badPath == "/nope/nope.toml")
            } else {
                #expect(Bool(false), "wrong LoadError case: \(error)")
            }
        } catch {
            #expect(Bool(false), "wrong error type: \(error)")
        }
    }

    @Test("resolved layers env vars on top of the file")
    func resolvedLayersEnvOnTop() {
        let file = ServerConfigurationFile(
            port: 5500,
            serverName: "FromFile",
            dbPath: "/file/db",
            filesRoot: "/file/files",
            bootstrapAdmin: .init(login: "fileuser", password: "filepass")
        )
        let resolved = file.resolved(environment: [
            "HEIDRUN_PORT": "6600",
            "HEIDRUN_ADMIN_PASSWORD": "fromEnv"
        ])
        #expect(resolved.port == 6600)                            // env overrides
        #expect(resolved.serverName == "FromFile")                // file kept
        #expect(resolved.accountStorePath == "/file/db")          // file kept
        #expect(resolved.filesRootPath == "/file/files")          // file kept
        #expect(resolved.bootstrapAdmin?.login == "fileuser")     // file kept
        #expect(resolved.bootstrapAdmin?.password == "fromEnv")   // env overrides
    }

    @Test("resolved falls back to built-in defaults when both file and env are empty")
    func resolvedFallsBackToDefaults() {
        let file = ServerConfigurationFile()
        let resolved = file.resolved(environment: [:])
        #expect(resolved.port == 5500)
        #expect(resolved.serverName == "Heidrun")
        #expect(resolved.bootstrapAdmin?.login == "admin")
        #expect(resolved.bootstrapAdmin?.password == "admin")
    }

    @Test("user history defaults on; env and file can disable it")
    func userHistoryToggle() {
        // Default: on.
        #expect(ServerConfigurationFile().resolved(environment: [:]).userHistoryEnabled == true)
        // Env disables (accepts 0/false/no/off).
        #expect(ServerConfigurationFile().resolved(environment: ["HEIDRUN_USER_HISTORY": "0"]).userHistoryEnabled == false)
        #expect(ServerConfigurationFile().resolved(environment: ["HEIDRUN_USER_HISTORY": "false"]).userHistoryEnabled == false)
        // File disables; env (anything truthy) overrides the file back on.
        let file = ServerConfigurationFile(userHistoryEnabled: false)
        #expect(file.resolved(environment: [:]).userHistoryEnabled == false)
        #expect(file.resolved(environment: ["HEIDRUN_USER_HISTORY": "1"]).userHistoryEnabled == true)
    }

    @Test("audit log defaults on; retention defaults to 90; ip off")
    func auditDefaults() {
        let config = ServerConfigurationFile().resolved(environment: [:])
        #expect(config.auditLogEnabled == true)
        #expect(config.auditRetentionDays == 90)
        #expect(config.logIPAddresses == false)
    }

    @Test("audit env vars override the file")
    func auditEnvOverride() {
        let file = ServerConfigurationFile()
        let resolved = file.resolved(environment: [
            "HEIDRUN_AUDIT_LOG_ENABLED": "off",
            "HEIDRUN_AUDIT_RETENTION_DAYS": "30",
            "HEIDRUN_LOG_IP_ADDRESSES": "yes"
        ])
        #expect(resolved.auditLogEnabled == false)
        #expect(resolved.auditRetentionDays == 30)
        #expect(resolved.logIPAddresses == true)
    }

    @Test("audit_db_path derives a sibling of db_path when unset")
    func auditPathDerivation() {
        let file = ServerConfigurationFile(dbPath: "/var/lib/heidrun/heidrun.sqlite")
        let resolved = file.resolved(environment: [:])
        #expect(resolved.auditDBPath == "/var/lib/heidrun/heidrun.audit.sqlite")
    }

    @Test("deprecated user_history_enabled drives the master switch when audit unset")
    func userHistoryAliasHonored() {
        let file = ServerConfigurationFile(userHistoryEnabled: false)
        #expect(file.resolved(environment: [:]).auditLogEnabled == false)
    }
}
