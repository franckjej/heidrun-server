import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Server integration", .serialized)
struct ServerIntegrationTests {

    // MARK: - Helpers

    private func makeServer() async throws -> (server: HeidrunServer, port: UInt16) {
        let server = HeidrunServer(configuration: ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test"
        ))
        let port = try await server.start()
        return (server, port)
    }

    private func connectAndLogin(
        port: UInt16,
        nickname: String,
        loginName: String = "",
        password: String = ""
    ) async throws -> any HotlineClient {
        let settings = ConnectionSettings(
            name: "loopback",
            address: "127.0.0.1",
            port: port,
            nickname: nickname,
            login: loginName
        )
        let client = try await HotlineNetworkClient.connect(settings: settings)
        try await client.login(name: loginName, password: password, nickname: nickname, icon: 0)
        return client
    }

    // MARK: - Tests

    @Test("client connects, logs in, sees itself in the user list")
    func loginAndUserList() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let client = try await connectAndLogin(port: port, nickname: "Frank")

        // Give the server a moment to register the session
        try await Task.sleep(for: .milliseconds(100))

        let users = try await client.fetchUserList()
        #expect(users.count == 1)
        #expect(users.first?.nickname == "Frank")
    }

    @Test("two clients see each other in the user list and receive a chat broadcast")
    func twoClientChatBroadcast() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let alice = try await connectAndLogin(port: port, nickname: "Alice")
        let bob = try await connectAndLogin(port: port, nickname: "Bob")

        // Allow both sessions to be fully registered server-side
        try await Task.sleep(for: .milliseconds(200))

        let users = try await bob.fetchUserList()
        let nicknames = Set(users.map(\.nickname))
        #expect(nicknames == Set(["Alice", "Bob"]))

        // Arm event collectors before sending the chat line so neither misses the push.
        // Each collector returns a Bool via its Task value — no shared mutable state.
        let aliceCollector = Task { () -> Bool in
            for await event in alice.events {
                if case let .chatReceived(_, message, _) = event, message.contains("hello") {
                    return true
                }
            }
            return false
        }
        let bobCollector = Task { () -> Bool in
            for await event in bob.events {
                if case let .chatReceived(_, message, _) = event, message.contains("hello") {
                    return true
                }
            }
            return false
        }

        try await alice.sendChat("hello", in: nil, isAction: false)

        // Race both collectors against a 2-second timeout.
        // The group resolves as soon as the first child finishes:
        //   • timeout child throws  → propagates, test fails
        //   • a collector child finishes first → we cancel the rest and check results
        let (aliceReceivedChat, bobReceivedChat): (Bool, Bool) = try await withThrowingTaskGroup(
            of: Void.self
        ) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw NSError(
                    domain: "ServerIntegrationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for chat broadcast"]
                )
            }
            group.addTask { _ = await aliceCollector.value }
            group.addTask { _ = await bobCollector.value }
            // Consume first two non-timeout completions (or throw on timeout)
            try await group.next()
            try await group.next()
            group.cancelAll()
            return (await aliceCollector.value, await bobCollector.value)
        }

        #expect(aliceReceivedChat)
        #expect(bobReceivedChat)
    }
}
