import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Admin transactions", .serialized)
struct AdminTransactionTests {
    private static let testRounds = 1_000

    private func withAdminServer<Result>(
        body: (HeidrunServer, UInt16) async throws -> Result
    ) async throws -> Result {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            accountStorePath: nil,
            passwordRounds: Self.testRounds,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin",
                password: "admin-pw",
                nickname: "Admin"
            )
        )
        let server = HeidrunServer(configuration: configuration)
        let port = try await server.start()
        do {
            let result = try await body(server, port)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    private func connectAdmin(port: UInt16) async throws -> any HotlineClient {
        try await ServerTestHelpers.connectAndLogin(
            port: port,
            nickname: "Admin",
            loginName: "admin",
            password: "admin-pw"
        )
    }

    @Test("createLogin (350) creates a new account and the new credentials work for login")
    func createLogin() async throws {
        try await withAdminServer { _, port in
            let admin = try await connectAdmin(port: port)

            try await admin.createLogin(
                name: "bob",
                password: "bob-pw",
                nickname: "Bob",
                privileges: []
            )

            // The newly-created account should now log in.
            let bob = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Bob",
                loginName: "bob",
                password: "bob-pw"
            )
            _ = bob
            // Admin sees two users in the list now.
            try await Task.sleep(for: .milliseconds(150))
            let users = try await admin.fetchUserList()
            let nicknames = Set(users.map(\.nickname))
            #expect(nicknames.contains("Bob"))
        }
    }

    @Test("guest createLogin attempt fails — createAccounts privilege required")
    func guestCannotCreateLogin() async throws {
        try await withAdminServer { _, port in
            let guest = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Guest")
            do {
                try await guest.createLogin(
                    name: "evil",
                    password: "x",
                    nickname: "Evil",
                    privileges: []
                )
                #expect(Bool(false), "expected createLogin to throw for guest")
            } catch {
                // expected
            }
        }
    }

    @Test("deleteLogin (351) removes an account; subsequent login fails")
    func deleteLogin() async throws {
        try await withAdminServer { _, port in
            let admin = try await connectAdmin(port: port)
            try await admin.createLogin(
                name: "carol",
                password: "carol-pw",
                nickname: "Carol",
                privileges: []
            )
            try await admin.deleteLogin("carol")

            // Login with Carol's now-deleted credentials should fail.
            let settings = ConnectionSettings(
                name: "loopback",
                address: "127.0.0.1",
                port: port,
                nickname: "Carol",
                login: "carol"
            )
            let attemptingClient = try await HotlineNetworkClient.connect(settings: settings)
            do {
                try await attemptingClient.login(
                    name: "carol",
                    password: "carol-pw",
                    nickname: "Carol",
                    icon: 0
                )
                #expect(Bool(false), "expected login to fail after delete")
            } catch {
                // expected
            }
        }
    }

    @Test("openLogin (352) returns nickname + privileges (password elided)")
    func openLogin() async throws {
        try await withAdminServer { _, port in
            let admin = try await connectAdmin(port: port)
            try await admin.createLogin(
                name: "dave",
                password: "dave-pw",
                nickname: "Dave the Diver",
                privileges: [.sendChat, .readNews]
            )
            let opened = try await admin.openLogin("dave")
            #expect(opened.nickname == "Dave the Diver")
            #expect(opened.privileges.contains(.sendChat))
            #expect(opened.privileges.contains(.readNews))
        }
    }

    @Test("modifyLogin (353) updates nickname + privileges; new password works")
    func modifyLogin() async throws {
        try await withAdminServer { _, port in
            let admin = try await connectAdmin(port: port)
            try await admin.createLogin(
                name: "ed",
                password: "old-pw",
                nickname: "Ed",
                privileges: []
            )
            try await admin.modifyLogin(
                name: "ed",
                password: "new-pw",
                nickname: "Edward",
                privileges: [.sendChat]
            )
            // Old credentials no longer work.
            let oldSettings = ConnectionSettings(
                name: "loopback",
                address: "127.0.0.1",
                port: port,
                nickname: "Edward",
                login: "ed"
            )
            let oldClient = try await HotlineNetworkClient.connect(settings: oldSettings)
            do {
                try await oldClient.login(name: "ed", password: "old-pw", nickname: "Edward", icon: 0)
                #expect(Bool(false), "old password should not work")
            } catch {}

            // New credentials succeed.
            let newClient = try await HotlineNetworkClient.connect(settings: oldSettings)
            try await newClient.login(name: "ed", password: "new-pw", nickname: "Edward", icon: 0)
        }
    }
}
