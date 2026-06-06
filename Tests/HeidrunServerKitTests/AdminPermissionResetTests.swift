import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Admin permission reset hook (HEIDRUN_RESET_ADMIN_PERMISSIONS)", .serialized)
struct AdminPermissionResetTests {

    /// Bitset that pre-`8a78eb1` (May 22 2026) deployments seeded their
    /// bootstrap admin with — only the five privilege bits the server
    /// directly enforced at the time. Notably missing `.canBroadcast`
    /// (bit 32), which the test uses as its observable signal.
    private static let legacyAdminPermissions: UInt64 =
        AccountPrivilege.createAccounts.rawValue
        | AccountPrivilege.deleteAccounts.rawValue
        | AccountPrivilege.readAccounts.rawValue
        | AccountPrivilege.modifyAccounts.rawValue
        | AccountPrivilege.disconnectUsers.rawValue
        // sendChat so this legacy admin can still issue chat commands
        // under the strict sendChat gate — the test's signal is the
        // absence of `.canBroadcast`, not of chat.
        | UserPrivileges.sendChat.rawValue

    /// Pre-populate `dbPath` with an admin row at the legacy 5-bit
    /// permission level so `HeidrunServer.start` sees a populated table
    /// and skips `bootstrapIfEmpty`. The store's `DatabaseQueue` is
    /// closed when the helper returns (it goes out of scope), freeing
    /// the SQLite file for the server's own connection.
    private static func seedLegacyAdmin(at dbPath: String) async throws {
        let store = try AccountStore(path: dbPath, passwordRounds: 1)
        _ = try await store.create(
            login: "admin",
            password: "admin",
            nickname: "Admin",
            iconID: 0,
            permissions: legacyAdminPermissions
        )
    }

    @Test("reset=true rewrites a legacy admin so they can /broadcast")
    func resetUpgradesLegacyAdmin() async throws {
        let dbPath = NSTemporaryDirectory() + "heidrun-reset-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try await Self.seedLegacyAdmin(at: dbPath)

        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun reset test",
            accountStorePath: dbPath,
            passwordRounds: 1,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            idleAwayThreshold: nil,
            resetAdminPermissions: true
        )

        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin",
                loginName: "admin", password: "admin"
            )
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            // Pre-`8a78eb1` admin lacks `.canBroadcast`; if the reset
            // hook did NOT run, /broadcast would reply with a
            // permission-denied error and bob would receive nothing.
            // The test catches that case by timing out on
            // `awaitBroadcast`.
            let collector = Task { () -> String? in
                for await event in bob.events {
                    if case let .broadcastReceived(message) = event { return message }
                }
                return nil
            }
            try await admin.sendChat("/broadcast reset hook ran", in: nil, isAction: false)
            let received: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    collector.cancel()
                    return nil
                }
                group.addTask { await collector.value }
                let first = (await group.next()).flatMap { $0 }
                group.cancelAll()
                return first
            }
            #expect(received == "reset hook ran")
        }
    }

    @Test("reset=false leaves a legacy admin's permissions untouched")
    func defaultLeavesLegacyAdminAlone() async throws {
        let dbPath = NSTemporaryDirectory() + "heidrun-reset-noop-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        try await Self.seedLegacyAdmin(at: dbPath)

        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun reset test",
            accountStorePath: dbPath,
            passwordRounds: 1,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            idleAwayThreshold: nil
            // resetAdminPermissions defaults to false
        )

        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin",
                loginName: "admin", password: "admin"
            )
            try await Task.sleep(for: .milliseconds(150))

            // With the hook off, admin still lacks `.canBroadcast` and
            // /broadcast should reply with a private permission-denied
            // chat — confirming the legacy row was NOT auto-upgraded.
            let collector = Task { () -> String? in
                for await event in admin.events {
                    if case let .chatReceived(_, message, _) = event,
                       message.contains("Permission denied") {
                        return message
                    }
                }
                return nil
            }
            try await admin.sendChat("/broadcast should fail", in: nil, isAction: false)
            let denial: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    collector.cancel()
                    return nil
                }
                group.addTask { await collector.value }
                let first = (await group.next()).flatMap { $0 }
                group.cancelAll()
                return first
            }
            let line = try #require(denial)
            #expect(line.contains("/broadcast requires the canBroadcast privilege"))
        }
    }
}
