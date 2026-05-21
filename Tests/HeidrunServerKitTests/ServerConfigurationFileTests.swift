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
}
