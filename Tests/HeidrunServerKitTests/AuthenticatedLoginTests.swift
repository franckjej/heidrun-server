import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Authenticated login", .serialized)
struct AuthenticatedLoginTests {
    private static let testRounds = 1_000

    /// Spin up a server seeded with one admin account via the
    /// `bootstrapAdmin` config knob. Guarantees `server.stop()` runs.
    private func withAuthServer<Result>(
        adminLogin: String = "alice",
        adminPassword: String = "hunter2",
        body: (HeidrunServer, UInt16) async throws -> Result
    ) async throws -> Result {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            accountStorePath: nil,
            passwordRounds: Self.testRounds,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: adminLogin,
                password: adminPassword,
                nickname: "Alice"
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

    @Test("login with valid registered credentials succeeds and fetches the user list")
    func loginWithValidCredentials() async throws {
        try await withAuthServer { _, port in
            let settings = ConnectionSettings(
                name: "loopback",
                address: "127.0.0.1",
                port: port,
                nickname: "Alice",
                login: "alice"
            )
            let client = try await HotlineNetworkClient.connect(settings: settings)
            try await client.login(
                name: "alice",
                password: "hunter2",
                nickname: "Alice",
                icon: 0
            )
            let users = try await client.fetchUserList()
            #expect(users.count == 1)
            #expect(users.first?.nickname == "Alice")
        }
    }

    @Test("login with a wrong password fails with an error reply")
    func loginWithBadPassword() async throws {
        try await withAuthServer { _, port in
            let settings = ConnectionSettings(
                name: "loopback",
                address: "127.0.0.1",
                port: port,
                nickname: "Alice",
                login: "alice"
            )
            let client = try await HotlineNetworkClient.connect(settings: settings)
            do {
                try await client.login(
                    name: "alice",
                    password: "wrong",
                    nickname: "Alice",
                    icon: 0
                )
                #expect(Bool(false), "expected login to throw")
            } catch {
                // expected — server replies with errorID = 1
            }
        }
    }

    @Test("guest login still works when no credentials are supplied")
    func guestLoginStillWorks() async throws {
        try await withAuthServer { _, port in
            let settings = ConnectionSettings(
                name: "loopback",
                address: "127.0.0.1",
                port: port,
                nickname: "GuestBob",
                login: ""
            )
            let client = try await HotlineNetworkClient.connect(settings: settings)
            try await client.login(name: "", password: "", nickname: "GuestBob", icon: 0)
            let users = try await client.fetchUserList()
            #expect(users.first?.nickname == "GuestBob")
        }
    }
}
