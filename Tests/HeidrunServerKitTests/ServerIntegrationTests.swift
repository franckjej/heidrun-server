import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Server integration", .serialized)
struct ServerIntegrationTests {

    // MARK: - Helpers

    /// Spin up a server on an ephemeral port, run `body`, and guarantee
    /// `await server.stop()` completes before this function returns —
    /// including on a thrown error from `body`. Eliminates the deferred-
    /// Task race where one test's cleanup overlaps the next test's setup
    /// and NIO emits "EventLoop already shut down" warnings.
    private func withRunningServer<Result>(
        configuration: ServerConfiguration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test"
        ),
        body: (HeidrunServer, UInt16) async throws -> Result
    ) async throws -> Result {
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
        try await withRunningServer { _, port in
            let client = try await connectAndLogin(port: port, nickname: "Frank")
            try await Task.sleep(for: .milliseconds(100))
            let users = try await client.fetchUserList()
            #expect(users.count == 1)
            #expect(users.first?.nickname == "Frank")
        }
    }

    @Test("two clients see each other in the user list and receive a chat broadcast")
    func twoClientChatBroadcast() async throws {
        try await withRunningServer { _, port in
            let alice = try await connectAndLogin(port: port, nickname: "Alice")
            let bob = try await connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(200))

            let users = try await bob.fetchUserList()
            let nicknames = Set(users.map(\.nickname))
            #expect(nicknames == Set(["Alice", "Bob"]))

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
                try await group.next()
                try await group.next()
                group.cancelAll()
                return (await aliceCollector.value, await bobCollector.value)
            }

            #expect(aliceReceivedChat)
            #expect(bobReceivedChat)
        }
    }

    @Test("server pushes the configured agreement after login")
    func pushesAgreement() async throws {
        try await withRunningServer(
            configuration: ServerConfiguration(
                port: 0,
                serverName: "Heidrun integration test",
                agreement: "Welcome to the test server."
            )
        ) { _, port in
            let client = try await connectAndLogin(port: port, nickname: "Frank")

            let observer = Task { () -> Bool in
                for await event in client.events {
                    if case let .agreementReceived(text, _) = event, text.contains("test server") {
                        return true
                    }
                }
                return false
            }

            let sawAgreement: Bool = try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw NSError(
                        domain: "ServerIntegrationTests",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for agreement"]
                    )
                }
                group.addTask { _ = await observer.value }
                try await group.next()
                group.cancelAll()
                return await observer.value
            }

            #expect(sawAgreement)
        }
    }

    @Test("when a client disconnects, remaining clients see userLeft (transID 302)")
    func userLeavesOnDisconnect() async throws {
        try await withRunningServer { _, port in
            let alice = try await connectAndLogin(port: port, nickname: "Alice")
            let bob = try await connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(200))

            let observer = Task { () -> UInt16? in
                for await event in alice.events {
                    if case let .userLeft(socket) = event {
                        return socket
                    }
                }
                return nil
            }

            await bob.disconnect()

            let leftSocket: UInt16? = try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw NSError(
                        domain: "ServerIntegrationTests",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for userLeft"]
                    )
                }
                group.addTask { _ = await observer.value }
                try await group.next()
                group.cancelAll()
                return await observer.value
            }

            #expect(leftSocket != nil)
            #expect(leftSocket != 0)
        }
    }
}
