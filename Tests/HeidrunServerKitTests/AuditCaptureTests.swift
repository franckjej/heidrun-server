import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Audit capture", .serialized)
struct AuditCaptureTests {
    /// A config with a real on-disk audit DB in a temp dir so a second
    /// AuditLog can read what the server wrote. Audit on, IP off.
    static func auditConfig(filesRoot: String? = nil) -> (ServerConfiguration, String) {
        let dir = NSTemporaryDirectory() + "heidrun-audit-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let auditPath = dir + "/audit.sqlite"
        let config = ServerConfiguration(
            port: 0,
            serverName: "audit test",
            accountStorePath: dir + "/accounts.sqlite",
            bootstrapAdmin: .init(login: "admin", password: "admin", nickname: "Admin"),
            filesRootPath: filesRoot,
            auditLogEnabled: true,
            auditDBPath: auditPath,
            logIPAddresses: false
        )
        return (config, auditPath)
    }

    @Test("a successful login writes a login_ok row")
    func loginOKRecorded() async throws {
        let (config, auditPath) = Self.auditConfig()
        try await ServerTestHelpers.withRunningServer(configuration: config) { _, port in
            _ = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin", loginName: "admin", password: "admin"
            )
            try await Task.sleep(for: .milliseconds(200))
            let reader = try AuditLog(path: auditPath, retentionDays: 90)
            let rows = await reader.query(type: [.loginOK], account: nil, withinHours: 1, limit: 50)
            #expect(rows.contains { $0.account == "admin" })
        }
    }

    @Test("a failed login writes a login_fail row carrying the attempted account")
    func loginFailRecorded() async throws {
        let (config, auditPath) = Self.auditConfig()
        try await ServerTestHelpers.withRunningServer(configuration: config) { _, port in
            let settings = ConnectionSettings(
                name: "loopback", address: "127.0.0.1", port: port,
                nickname: "Mallory", login: "admin"
            )
            let client = try await HotlineNetworkClient.connect(settings: settings)
            _ = try? await client.login(
                name: "admin", password: "wrong", nickname: "Mallory", icon: 0, emoji: nil
            )
            try await Task.sleep(for: .milliseconds(200))
            let reader = try AuditLog(path: auditPath, retentionDays: 90)
            let rows = await reader.query(type: [.loginFail], account: nil, withinHours: 1, limit: 50)
            #expect(rows.contains { $0.account == "admin" })
        }
    }

    @Test("creating an account writes an account_create row naming the target")
    func accountCreateRecorded() async throws {
        let (config, auditPath) = Self.auditConfig()
        try await ServerTestHelpers.withRunningServer(configuration: config) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin", loginName: "admin", password: "admin"
            )
            try await admin.createLogin(
                name: "newbie", password: "pw", nickname: "Newbie", privileges: []
            )
            try await Task.sleep(for: .milliseconds(200))
            let reader = try AuditLog(path: auditPath, retentionDays: 90)
            let rows = await reader.query(type: [.accountCreate], account: nil, withinHours: 1, limit: 50)
            #expect(rows.contains { $0.target == "newbie" && $0.account == "admin" })
        }
    }
}
