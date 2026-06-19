import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

// Second half of the chat slash-command suite — split out of
// ChatCommandsTests.swift to stay under the file/type-length limits.
// Shares the (now internal) static await/expect helpers on the suite type.
extension ChatCommandsTests {
    // MARK: - /kick

    @Test("/kick from a canDisconnect holder boots the target; witnesses see userLeft")
    func kickAdminPath() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin",
                password: "admin",
                nickname: "Admin"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )
            let target = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Target")
            let witness = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Witness")
            try await Task.sleep(for: .milliseconds(150))

            let users = try await witness.fetchUserList()
            let targetSocket = try #require(users.first(where: { $0.nickname == "Target" })?.socket)

            // Witness observes userLeft for the target's socket.
            let leftWatcher = Task { () -> Bool in
                for await event in witness.events {
                    if case let .userLeft(socket) = event, socket == targetSocket {
                        return true
                    }
                }
                return false
            }
            async let confirmation = Self.awaitChat(admin) { $0.contains("Kicked Target") }

            try await admin.sendChat("/kick \(targetSocket)", in: nil, isAction: false)

            let kicked: Bool = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    leftWatcher.cancel()
                    return false
                }
                group.addTask { await leftWatcher.value }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            let line = try await confirmation
            #expect(kicked, "witness should see userLeft for the kicked socket")
            #expect(line.contains("*** Kicked Target (socket=\(targetSocket))"))
            _ = target  // silence the unused-binding warning; we don't query the kicked client
        }
    }

    @Test("/kick from a guest is rejected; target stays connected")
    func kickGuestRejected() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let guest = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Guest")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let users = try await guest.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)

            async let error = Self.awaitChat(guest) { $0.contains("Permission denied") }
            try await guest.sendChat("/kick \(bobSocket)", in: nil, isAction: false)

            let line = try await error
            #expect(line.contains("/kick requires the disconnectUsers privilege"))

            // Sanity: bob is still in the roster.
            try await Task.sleep(for: .milliseconds(200))
            let after = try await guest.fetchUserList()
            #expect(after.contains { $0.nickname == "Bob" })
        }
    }

    @Test("/kick refuses self-kick")
    func kickSelfRefused() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin",
                password: "admin",
                nickname: "Admin"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )
            try await Task.sleep(for: .milliseconds(150))

            let users = try await admin.fetchUserList()
            let adminSocket = try #require(users.first(where: { $0.nickname == "Admin" })?.socket)

            async let reply = Self.awaitChat(admin) { $0.contains("yourself") }
            try await admin.sendChat("/kick \(adminSocket)", in: nil, isAction: false)

            let line = try await reply
            #expect(line.contains("*** Can't kick yourself."))
        }
    }

    // MARK: - /invisible + /visible

    @Test("/invisible broadcasts userLeft and removes the admin from peers' user list")
    func invisibleHidesFromPeers() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            idleAwayThreshold: nil
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin",
                loginName: "admin", password: "admin"
            )
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            // Capture admin's socketID from bob's perspective.
            let pre = try await bob.fetchUserList()
            let adminSocket = try #require(pre.first(where: { $0.nickname == "Admin" })?.socket)

            // Bob expects a userLeft for admin's socket.
            let leftWatcher = Task { () -> Bool in
                for await event in bob.events {
                    if case let .userLeft(socket) = event, socket == adminSocket {
                        return true
                    }
                }
                return false
            }
            try await admin.sendChat("/invisible", in: nil, isAction: false)

            let saw: Bool = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    leftWatcher.cancel()
                    return false
                }
                group.addTask { await leftWatcher.value }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(saw, "bob should receive userLeft for the invisible admin")

            // Subsequent user-list request must omit the admin.
            try await Task.sleep(for: .milliseconds(100))
            let after = try await bob.fetchUserList()
            #expect(!after.contains { $0.nickname == "Admin" })
        }
    }

    @Test("/visible re-broadcasts userChanged so peers can re-add the row")
    func visibleRestoresToPeers() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            idleAwayThreshold: nil
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin",
                loginName: "admin", password: "admin"
            )
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            try await admin.sendChat("/invisible", in: nil, isAction: false)
            try await Task.sleep(for: .milliseconds(150))

            async let restored = Self.awaitUserChanged(bob) { $0.nickname == "Admin" }
            try await admin.sendChat("/visible", in: nil, isAction: false)

            let user = try await restored
            #expect(user.nickname == "Admin")

            let after = try await bob.fetchUserList()
            #expect(after.contains { $0.nickname == "Admin" })
        }
    }

    @Test("invisible admin still sees themselves in their own /who")
    func invisibleAdminSelfInWho() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            idleAwayThreshold: nil
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin",
                loginName: "admin", password: "admin"
            )
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            try await admin.sendChat("/invisible", in: nil, isAction: false)
            try await Task.sleep(for: .milliseconds(150))

            async let reply = Self.awaitChat(admin) { $0.contains("Connected users") }
            try await admin.sendChat("/who", in: nil, isAction: false)

            let block = try await reply
            #expect(block.contains("Admin (socket="), "admin should always see themselves in /who")
            #expect(block.contains("Bob (socket="))
            _ = bob
        }
    }

    @Test("/invisible from a guest is rejected; admin stays visible")
    func invisibleGuestRejected() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            idleAwayThreshold: nil
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin",
                loginName: "admin", password: "admin"
            )
            let guest = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Guest")
            try await Task.sleep(for: .milliseconds(150))

            async let reply = Self.awaitChat(guest) { $0.contains("Permission denied") }
            try await guest.sendChat("/invisible", in: nil, isAction: false)

            let line = try await reply
            #expect(line.contains("/invisible requires the disconnectUsers privilege"))

            // Sanity: admin still in the roster.
            let users = try await guest.fetchUserList()
            #expect(users.contains { $0.nickname == "Admin" })
        }
    }

    // MARK: - Unknown / parser edges

    @Test("unknown /command replies privately and is never broadcast")
    func unknownCommandPrivateReply() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let aliceReply = Self.awaitChat(alice) { $0.contains("Unknown command") }
            async let bobSilent: Void = Self.expectNoChat(bob) { $0.contains("/madeup") }

            try await alice.sendChat("/madeup arg1 arg2", in: nil, isAction: false)

            let reply = try await aliceReply
            await bobSilent
            #expect(reply.contains("*** Unknown command: /madeup"))
        }
    }

    @Test("command head is case-insensitive")
    func caseInsensitive() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(alice) { $0.contains("HeidrunServer") }
            try await alice.sendChat("/VERSION", in: nil, isAction: false)
            _ = try await reply  // throws on timeout
        }
    }

    @Test("body of just '/' falls through as normal chat (not a command)")
    func bareSlashFallsThrough() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            // bob should see a normal chat broadcast — proof we didn't
            // accidentally swallow the line.
            async let bobReceives = Self.awaitChat(bob) { $0.contains("Alice") && $0.contains("/") }
            try await alice.sendChat("/", in: nil, isAction: false)
            let line = try await bobReceives
            #expect(line.contains("Alice: /"))
        }
    }

    @Test("'//' prefix falls through as normal chat (not a command)")
    func doubleSlashFallsThrough() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let bobReceives = Self.awaitChat(bob) { $0.contains("//emph") }
            try await alice.sendChat("//emph", in: nil, isAction: false)
            let line = try await bobReceives
            #expect(line.contains("Alice: //emph"))
        }
    }

    // MARK: - Public chat topic

    @Test("a configured topic is pushed to a client on login")
    func topicPushedOnLogin() async throws {
        let path = NSTemporaryDirectory() + "chatsubject-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Topic test",
            chatSubject: "Daily topic",
            chatSubjectStatePath: path
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let subject = try await Self.awaitSubject(alice)
            #expect(subject == "Daily topic")
        }
    }

    @Test("/topic from a canBroadcast holder sets + broadcasts the public subject")
    func topicAdminPath() async throws {
        let path = NSTemporaryDirectory() + "chatsubject-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Topic test",
            chatSubjectStatePath: path,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin",
                password: "admin",
                nickname: "Admin"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin", loginName: "admin", password: "admin"
            )
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let bobSubject = Self.awaitSubject(bob)
            async let adminConfirm = Self.awaitChat(admin) { $0.contains("Topic set") }

            try await admin.sendChat("/topic Welcome to tastybytes", in: nil, isAction: false)

            #expect(try await bobSubject == "Welcome to tastybytes")
            #expect(try await adminConfirm.contains("Topic set"))
        }
    }

    @Test("/topic from a guest is rejected")
    func topicGuestRejected() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let guest = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Snooper")
            try await Task.sleep(for: .milliseconds(150))
            async let errorLine = Self.awaitChat(guest) { $0.contains("Permission denied") }
            try await guest.sendChat("/topic hijack the room", in: nil, isAction: false)
            #expect(try await errorLine.contains("/topic requires the canBroadcast privilege"))
        }
    }

    @Test("/usershistory lists entered/left for an admin caller")
    func usersHistoryAsAdmin() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin", loginName: "admin", password: "admin"
            )
            // A guest enters, then leaves.
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))
            await bob.disconnect()

            // `disconnect()` returns before the server's async cleanup
            // records the `.left` event, so poll the real condition (the
            // history listing Bob's leave) rather than guess a fixed delay.
            var block = ""
            for _ in 0..<40 {
                async let reply = Self.awaitChat(admin) { $0.contains("User history") }
                try await admin.sendChat("/usershistory", in: nil, isAction: false)
                block = try await reply
                if block.contains(") left") { break }
                try await Task.sleep(for: .milliseconds(50))
            }

            // Lines carry the socket ID so two same-named logins are
            // distinguishable: "  HH:mm:ss  Bob (N) entered".
            #expect(block.contains("User history (last 1h):"))
            #expect(block.contains("Bob ("))
            #expect(block.contains(") entered"))
            #expect(block.contains(") left"))
        }
    }

    @Test("/usershistory is denied for a non-admin")
    func usersHistoryDeniedForGuest() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(alice) { $0.contains("Permission denied") }
            try await alice.sendChat("/usershistory", in: nil, isAction: false)
            let line = try await reply
            #expect(line.contains("/usershistory requires the disconnectUsers privilege"))
        }
    }

    @Test("/usershistory reports disabled when the kill-switch is off")
    func usersHistoryDisabled() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            ),
            auditLogEnabled: false
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Admin", loginName: "admin", password: "admin"
            )
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(admin) { $0.contains("disabled") }
            try await admin.sendChat("/history", in: nil, isAction: false)  // alias
            let line = try await reply
            #expect(line.contains("Audit log is disabled on this server."))
        }
    }

    @Test("a user without sendChat cannot issue chat commands (strict gate)")
    func noSendChatBlocksCommands() async throws {
        // Seed a read-only account: it can receive chat but lacks
        // sendChat, so the strict gate must reject its whole chat input —
        // including slash commands — before any command runs.
        let dbPath = NSTemporaryDirectory() + "heidrun-mute-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let mutedPermissions = UserPrivileges.readChat.rawValue | UserPrivileges.readNews.rawValue
        do {
            let store = try AccountStore(path: dbPath, passwordRounds: 1)
            _ = try await store.create(
                login: "muted", password: "pw", nickname: "Muted",
                iconID: 0, permissions: mutedPermissions)
        }
        let configuration = ServerConfiguration(
            port: 0, accountStorePath: dbPath, passwordRounds: 1)
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let muted = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Muted", loginName: "muted", password: "pw")
            try await Task.sleep(for: .milliseconds(100))
            // `/who` normally replies with a roster dump; the strict gate
            // rejects the chat input first, so nothing comes back.
            async let silent: Void = Self.expectNoChat(muted) { $0.contains("Connected users") }
            try await muted.sendChat("/who", in: nil, isAction: false)
            await silent
        }
    }
}
