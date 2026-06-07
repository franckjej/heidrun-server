import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

enum ServerTestHelpers {
    /// Spin up a server on an ephemeral port, run `body`, and guarantee
    /// `await server.stop()` completes before this function returns —
    /// including on a thrown error from `body`. Eliminates the deferred-
    /// Task race where one test's cleanup overlaps the next test's setup
    /// and NIO emits "EventLoop already shut down" warnings.
    static func withRunningServer<Result>(
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

    static func connectAndLogin(
        port: UInt16,
        nickname: String,
        loginName: String = "",
        password: String = "",
        emoji: String? = nil
    ) async throws -> any HotlineClient {
        let settings = ConnectionSettings(
            name: "loopback",
            address: "127.0.0.1",
            port: port,
            nickname: nickname,
            login: loginName
        )
        let client = try await HotlineNetworkClient.connect(settings: settings)
        try await client.login(
            name: loginName, password: password, nickname: nickname, icon: 0, emoji: emoji)
        return client
    }
}

/// Captures raw inbound packets via a `PacketObserver` — lets a test see
/// server pushes that the client's dispatch intentionally swallows (e.g. a
/// privileges-only TX 354, which decodes to no roster and no event).
actor PacketRecorder {
    private var packets: [(header: PacketHeader, fields: [PacketField])] = []
    func record(header: PacketHeader, fields: [PacketField]) {
        packets.append((header, fields))
    }
    func inbound(transactionID: UInt16) -> [(header: PacketHeader, fields: [PacketField])] {
        packets.filter { $0.header.transactionID == transactionID }
    }
}

@Suite("Server integration", .serialized)
struct ServerIntegrationTests {

    // MARK: - Tests

    @Test("login pushes a User Access bitmap (TX 354) carrying the account's privileges")
    func loginPushesUserAccess() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            sendUserAccess: true   // opt-in; off by default (see below)
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let recorder = PacketRecorder()
            let observer = PacketObserver { direction, header, fields in
                guard direction == .inbound else { return }
                Task { await recorder.record(header: header, fields: fields) }
            }
            let settings = ConnectionSettings(
                name: "loopback", address: "127.0.0.1", port: port,
                nickname: "Admin", login: "admin")
            let client = try await HotlineNetworkClient.connect(
                settings: settings, packetObserver: observer)
            try await client.login(name: "admin", password: "admin", nickname: "Admin", icon: 0)
            // Let the post-login pushes (354 / agreement / topic) land.
            try await Task.sleep(for: .milliseconds(250))

            let access = await recorder.inbound(transactionID: 354)
            let push = try #require(access.first,
                "server must push a User Access (TX 354) after login")
            #expect(push.header.classID == 0, "User Access is a push, not a reply")
            let privField = try #require(push.fields.first(.privileges),
                "User Access must carry the privileges field (110)")
            #expect(privField.data.count == 8)
            let privileges = UserPrivileges(bytes: privField.data)
            #expect(privileges.rawValue != 0, "admin must receive a non-empty privileges bitmap")
            #expect(privileges.contains(.canBroadcast), "bootstrap admin holds every privilege")

            await client.disconnect()
        }
    }

    @Test("User Access push is omitted by default (opt-in only)")
    func loginOmitsUserAccessByDefault() async throws {
        // No `sendUserAccess` → defaults off → no 354, so pre-rc18 clients
        // keep their roster.
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let recorder = PacketRecorder()
            let observer = PacketObserver { direction, header, fields in
                guard direction == .inbound else { return }
                Task { await recorder.record(header: header, fields: fields) }
            }
            let settings = ConnectionSettings(
                name: "loopback", address: "127.0.0.1", port: port,
                nickname: "Admin", login: "admin")
            let client = try await HotlineNetworkClient.connect(
                settings: settings, packetObserver: observer)
            try await client.login(name: "admin", password: "admin", nickname: "Admin", icon: 0)
            try await Task.sleep(for: .milliseconds(250))

            #expect(await recorder.inbound(transactionID: 354).isEmpty,
                "354 must not be sent unless send_user_access is enabled")
            await client.disconnect()
        }
    }

    @Test("client connects, logs in, sees itself in the user list")
    func loginAndUserList() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            try await Task.sleep(for: .milliseconds(100))
            let users = try await client.fetchUserList()
            #expect(users.count == 1)
            #expect(users.first?.nickname == "Frank")
        }
    }

    @Test("emoji set at login appears in another user's user list")
    func emojiPropagatesToUserList() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Alice")
            _ = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Bob", emoji: "🎸")
            try await Task.sleep(for: .milliseconds(200))

            let users = try await alice.fetchUserList()
            let bob = try #require(users.first(where: { $0.nickname == "Bob" }))
            #expect(bob.emoji == "🎸")
        }
    }

    @Test("changeNickname updates the stored emoji for peers")
    func emojiUpdatesViaChangeNickname() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Bob")
            try await bob.changeNickname("Bob", icon: 0, emoji: "🌮", persist: false)
            try await Task.sleep(for: .milliseconds(200))

            let users = try await alice.fetchUserList()
            let bobUser = try #require(users.first(where: { $0.nickname == "Bob" }))
            #expect(bobUser.emoji == "🌮")
        }
    }

    @Test("two clients see each other in the user list and receive a chat broadcast")
    func twoClientChatBroadcast() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
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
        try await ServerTestHelpers.withRunningServer(
            configuration: ServerConfiguration(
                port: 0,
                serverName: "Heidrun integration test",
                agreement: "Welcome to the test server."
            )
        ) { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")

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
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
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

    @Test("server stop records exactly one departure for everyone still connected")
    func shutdownDrainsHistory() async throws {
        // Persistent DB so the history survives the server going down and
        // can be read back through a fresh store on the same file.
        let dbPath = NSTemporaryDirectory() + "heidrun-shutdown-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let server = HeidrunServer(
            configuration: ServerConfiguration(port: 0, accountStorePath: dbPath)
        )
        let port = try await server.start()
        let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Ghost")
        try await Task.sleep(for: .milliseconds(150))   // let login + entered land

        // Hard stop while Ghost is still connected — the shutdown drain
        // should record its leave even though no graceful client
        // disconnect happened.
        await server.stop()
        await client.disconnect()

        let store = try UserEventStore(path: dbPath)
        let events = await store.events(withinHours: 1)
        let ghostLeaves = events.filter { $0.nickname == "Ghost" && $0.kind == .left }
        #expect(events.contains { $0.nickname == "Ghost" && $0.kind == .entered })
        #expect(ghostLeaves.count == 1)   // recorded once, not doubled
    }
}
