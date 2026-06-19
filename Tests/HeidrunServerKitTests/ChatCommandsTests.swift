import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Chat slash commands", .serialized)
struct ChatCommandsTests {

    // MARK: - Helpers

    /// Wait up to `timeout` for the first chat event on `client` whose
    /// message matches `predicate`. Returns the matched string, or
    /// throws on timeout.
    static func awaitChat(
        _ client: any HotlineClient,
        timeout: Duration = .seconds(2),
        message predicate: @Sendable @escaping (String) -> Bool
    ) async throws -> String {
        let collector = Task { () -> String? in
            for await event in client.events {
                if case let .chatReceived(_, message, _) = event, predicate(message) {
                    return message
                }
            }
            return nil
        }
        let captured: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await Task.sleep(for: timeout)
                collector.cancel()
                return nil
            }
            group.addTask { await collector.value }
            let first = (await group.next()).flatMap { $0 }
            group.cancelAll()
            return first
        }
        guard let captured else {
            throw NSError(
                domain: "ChatCommandsTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for matching chat"]
            )
        }
        return captured
    }

    /// Assert `client` receives NO chat matching `predicate` within
    /// `timeout`. Used to verify a `/command` was NOT broadcast.
    static func expectNoChat(
        _ client: any HotlineClient,
        within timeout: Duration = .milliseconds(500),
        message predicate: @Sendable @escaping (String) -> Bool
    ) async {
        let collector = Task { () -> Bool in
            for await event in client.events {
                if case let .chatReceived(_, message, _) = event, predicate(message) {
                    return true
                }
            }
            return false
        }
        let saw: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: timeout)
                collector.cancel()
                return false
            }
            group.addTask { await collector.value }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(saw == false, "expected NO matching chat; got one")
    }

    /// Wait up to `timeout` for the first broadcastReceived (355)
    /// event on `client`. Returns the message body or throws on
    /// timeout.
    static func awaitBroadcast(
        _ client: any HotlineClient,
        timeout: Duration = .seconds(2)
    ) async throws -> String {
        let collector = Task { () -> String? in
            for await event in client.events {
                if case let .broadcastReceived(message) = event {
                    return message
                }
            }
            return nil
        }
        let captured: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await Task.sleep(for: timeout)
                collector.cancel()
                return nil
            }
            group.addTask { await collector.value }
            let first = (await group.next()).flatMap { $0 }
            group.cancelAll()
            return first
        }
        guard let captured else {
            throw NSError(
                domain: "ChatCommandsTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for broadcast"]
            )
        }
        return captured
    }

    /// Wait up to `timeout` for the first `privateChatSubjectChanged`
    /// (TX 119) event on `client`. Returns the subject or throws on
    /// timeout. Mirrors `awaitBroadcast`.
    static func awaitSubject(
        _ client: any HotlineClient,
        timeout: Duration = .seconds(2)
    ) async throws -> String {
        let collector = Task { () -> String? in
            for await event in client.events {
                if case let .privateChatSubjectChanged(_, subject) = event {
                    return subject
                }
            }
            return nil
        }
        let captured: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await Task.sleep(for: timeout)
                collector.cancel()
                return nil
            }
            group.addTask { await collector.value }
            let first = (await group.next()).flatMap { $0 }
            group.cancelAll()
            return first
        }
        guard let captured else {
            throw NSError(
                domain: "ChatCommandsTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for a chat subject"]
            )
        }
        return captured
    }

    /// Assert `client` receives NO broadcast (355) within `timeout`.
    static func expectNoBroadcast(
        _ client: any HotlineClient,
        within timeout: Duration = .milliseconds(500)
    ) async {
        let collector = Task { () -> Bool in
            for await event in client.events {
                if case .broadcastReceived = event { return true }
            }
            return false
        }
        let saw: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: timeout)
                collector.cancel()
                return false
            }
            group.addTask { await collector.value }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(saw == false, "expected NO broadcast; got one")
    }

    /// Wait up to `timeout` for the first userChanged event on `client`
    /// matching `predicate`. Returns the user or throws on timeout.
    static func awaitUserChanged(
        _ client: any HotlineClient,
        timeout: Duration = .seconds(2),
        matching predicate: @Sendable @escaping (User) -> Bool
    ) async throws -> User {
        let collector = Task { () -> User? in
            for await event in client.events {
                if case let .userChanged(user) = event, predicate(user) {
                    return user
                }
            }
            return nil
        }
        let captured: User? = await withTaskGroup(of: User?.self) { group in
            group.addTask {
                try? await Task.sleep(for: timeout)
                collector.cancel()
                return nil
            }
            group.addTask { await collector.value }
            let first = (await group.next()).flatMap { $0 }
            group.cancelAll()
            return first
        }
        guard let captured else {
            throw NSError(
                domain: "ChatCommandsTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for matching userChanged"]
            )
        }
        return captured
    }

    // MARK: - /version

    @Test("/version delivers version + build to sender only")
    func versionIsSenderOnly() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let aliceReply = Self.awaitChat(alice) { $0.contains("HeidrunServer") }
            async let bobSilent: Void = Self.expectNoChat(bob) { $0.contains("HeidrunServer") }

            try await alice.sendChat("/version", in: nil, isAction: false)

            let reply = try await aliceReply
            await bobSilent

            #expect(reply.contains("HeidrunServer \(HeidrunServerInfo.version)"))
            #expect(reply.contains("build:"))
            #expect(reply.contains("***"))
        }
    }

    @Test("/version build line honours HEIDRUN_BUILD / HEIDRUN_BUILD_DATE env vars")
    func versionPicksUpEnvOverride() async throws {
        setenv("HEIDRUN_BUILD", "abc1234", 1)
        setenv("HEIDRUN_BUILD_DATE", "2026-05-23", 1)
        defer {
            unsetenv("HEIDRUN_BUILD")
            unsetenv("HEIDRUN_BUILD_DATE")
        }

        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(alice) { $0.contains("build:") }
            try await alice.sendChat("/version", in: nil, isAction: false)

            let line = try await reply
            #expect(line.contains("build: abc1234 (2026-05-23)"))
        }
    }

    @Test("/version verbose block carries swift / platform / server / ports / uptime / users")
    func versionVerboseBlock() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "TestServerName"
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            // Wait until the reply has all the trailing lines — the
            // multi-line response arrives in one chatPush so this is a
            // single event with embedded \r separators.
            async let reply = Self.awaitChat(alice) { message in
                message.contains("users:")
                    && message.contains("uptime:")
                    && message.contains("swift:")
            }
            try await alice.sendChat("/version", in: nil, isAction: false)

            let block = try await reply
            #expect(block.contains("HeidrunServer \(HeidrunServerInfo.version)"))
            #expect(block.contains("swift: \(HeidrunServerInfo.swiftCompilerVersion)"))
            #expect(block.contains("platform: "))
            #expect(block.contains("server: TestServerName"))
            // OS-picked port so we can't predict the number — just
            // assert the line shape.
            #expect(block.contains("ports: "))
            #expect(block.contains("uptime: "))
            // Just Alice connected at this moment.
            #expect(block.contains("users: 1"))
        }
    }

    @Test("/version reads build id/date from HEIDRUN_BUILD_INFO_DIR when env vars are unset")
    func versionReadsFromBuildInfoFile() async throws {
        // Belt-and-braces: ensure neither env var leaks in from a
        // previous test or the host shell.
        unsetenv("HEIDRUN_BUILD")
        unsetenv("HEIDRUN_BUILD_DATE")

        let tempDir = NSTemporaryDirectory() + "heidrun-build-info-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        try "f00ba12\n".write(
            toFile: "\(tempDir)/build-id",
            atomically: true,
            encoding: .utf8
        )
        try "2026-05-23\n".write(
            toFile: "\(tempDir)/build-date",
            atomically: true,
            encoding: .utf8
        )
        setenv("HEIDRUN_BUILD_INFO_DIR", tempDir, 1)
        defer { unsetenv("HEIDRUN_BUILD_INFO_DIR") }

        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(alice) { $0.contains("build:") }
            try await alice.sendChat("/version", in: nil, isAction: false)

            let line = try await reply
            #expect(line.contains("build: f00ba12 (2026-05-23)"),
                    "expected file-baked stamp; got: \(line)")
        }
    }

    @Test("/version strips control bytes from a malformed build stamp")
    func versionStripsControlBytes() async throws {
        // Embed a literal newline in the stamp. The sanitiser must
        // remove it so the multi-line reply doesn't get an extra line.
        setenv("HEIDRUN_BUILD", "abc\n1234", 1)
        setenv("HEIDRUN_BUILD_DATE", "", 1)
        defer {
            unsetenv("HEIDRUN_BUILD")
            unsetenv("HEIDRUN_BUILD_DATE")
        }

        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(alice) { $0.contains("build:") }
            try await alice.sendChat("/version", in: nil, isAction: false)

            let line = try await reply
            #expect(line.contains("build: abc1234"))
            // The newline embedded in the env var must NOT survive into
            // the wire bytes — it would render as a phantom blank line.
            #expect(!line.contains("build: abc\n1234"))
        }
    }

    // MARK: - /away

    @Test("/away flips the away bit, broadcasts to all, toggle clears it")
    func awayToggle() async throws {
        // Idle supervisor disabled so it can't race the manual flag.
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            idleAwayThreshold: nil
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            // /away → bit set, broadcast to bob
            async let firstChange = Self.awaitUserChanged(bob) {
                $0.nickname == "Alice" && $0.status.flags.contains(.away)
            }
            try await alice.sendChat("/away", in: nil, isAction: false)
            let setUser = try await firstChange
            #expect(setUser.status.flags.contains(.away))

            // /away again → bit cleared, broadcast again
            async let secondChange = Self.awaitUserChanged(bob) {
                $0.nickname == "Alice" && !$0.status.flags.contains(.away)
            }
            try await alice.sendChat("/away", in: nil, isAction: false)
            let clearedUser = try await secondChange
            #expect(!clearedUser.status.flags.contains(.away))
        }
    }

    @Test("/away confirmation goes to the sender only")
    func awayConfirmationIsPrivate() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            idleAwayThreshold: nil
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let aliceReply = Self.awaitChat(alice) { $0.contains("now away") }
            async let bobSilent: Void = Self.expectNoChat(bob) { $0.contains("now away") }

            try await alice.sendChat("/away", in: nil, isAction: false)

            let reply = try await aliceReply
            await bobSilent
            #expect(reply.contains("*** You are now away."))
        }
    }

    @Test("/away on an admin preserves the red colour byte")
    func awayPreservesAdminColor() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin",
                password: "admin",
                nickname: "Admin"
            ),
            idleAwayThreshold: nil
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )
            let observer = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Observer")
            try await Task.sleep(for: .milliseconds(150))

            async let change = Self.awaitUserChanged(observer) {
                $0.nickname == "Admin" && $0.status.flags.contains(.away)
            }
            try await admin.sendChat("/away", in: nil, isAction: false)

            let user = try await change
            // High byte (colour) must survive the away-bit OR-in.
            // Admin baseline = palette 36 from Account.initialHotStatus.
            #expect(user.status.color == 36)
            #expect(user.status.flags.contains(.away))
            #expect(user.status.flags.contains(.admin))
        }
    }

    // MARK: - /broadcast

    @Test("/broadcast from a canBroadcast holder reaches every other client + sender confirmation")
    func broadcastAdminPath() async throws {
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
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let bobBroadcast = Self.awaitBroadcast(bob)
            async let bobChatFallback = Self.awaitChat(bob) { $0.contains("BROADCAST from Admin") }
            async let adminBroadcast = Self.awaitBroadcast(admin)
            async let adminConfirm = Self.awaitChat(admin) { $0.contains("Broadcast sent") }

            try await admin.sendChat("/broadcast server going down at midnight", in: nil, isAction: false)

            let bobReceived = try await bobBroadcast
            let bobChatLine = try await bobChatFallback
            let adminReceived = try await adminBroadcast
            let confirmation = try await adminConfirm

            #expect(bobReceived == "server going down at midnight")
            // Sender included so the operator sees their own message
            // as confirmation it landed via the same channel.
            #expect(adminReceived == "server going down at midnight")
            // Chat-window fallback for clients without a broadcast-popup UI.
            #expect(bobChatLine.contains("*** BROADCAST from Admin: server going down at midnight ***"))
            #expect(confirmation.contains("*** Broadcast sent."))
        }
    }

    @Test("/broadcast from a guest is rejected; no peer receives the message")
    func broadcastGuestRejected() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let guest = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Snooper")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let guestError = Self.awaitChat(guest) { $0.contains("Permission denied") }
            async let bobSilent: Void = Self.expectNoBroadcast(bob)

            try await guest.sendChat("/broadcast i shouldnt be able to do this", in: nil, isAction: false)

            let errorLine = try await guestError
            await bobSilent
            #expect(errorLine.contains("/broadcast requires the canBroadcast privilege"))
        }
    }

    @Test("/broadcast with no message surfaces a usage hint, no peer broadcast")
    func broadcastUsageHint() async throws {
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
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let usage = Self.awaitChat(admin) { $0.contains("Usage:") }
            async let bobSilent: Void = Self.expectNoBroadcast(bob)

            try await admin.sendChat("/broadcast    ", in: nil, isAction: false)

            let hint = try await usage
            await bobSilent
            #expect(hint.contains("*** Usage: /broadcast <message>"))
        }
    }

    // MARK: - /me

    @Test("/me broadcasts an action chat line to every session including the sender")
    func meAction() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let bobLine = Self.awaitChat(bob) { $0.contains("waves") }
            async let aliceLine = Self.awaitChat(alice) { $0.contains("waves") }

            try await alice.sendChat("/me waves at Bob", in: nil, isAction: false)

            let bobReceived = try await bobLine
            let aliceReceived = try await aliceLine
            // Mobius-style format: leading " *<nick> <action>".
            #expect(bobReceived.contains("*Alice waves at Bob"))
            #expect(aliceReceived.contains("*Alice waves at Bob"))
        }
    }

    // MARK: - /who, /uptime, /help

    @Test("/who lists every connected user with their socket id, sender-only")
    func whoListsRoster() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let reply = Self.awaitChat(alice) { $0.contains("Connected users") }
            async let bobSilent: Void = Self.expectNoChat(bob) { $0.contains("Connected users") }

            try await alice.sendChat("/who", in: nil, isAction: false)

            let block = try await reply
            await bobSilent
            #expect(block.contains("Connected users (2)"))
            #expect(block.contains("Alice (socket="))
            #expect(block.contains("Bob (socket="))
        }
    }

    @Test("/whoami returns the caller's session block; admin shows admin=true + privilege hex")
    func whoamiAsAdmin() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            async let reply = Self.awaitChat(admin) { $0.contains("permissions:") }
            async let bobSilent: Void = Self.expectNoChat(bob) { $0.contains("permissions:") }

            try await admin.sendChat("/whoami", in: nil, isAction: false)

            let block = try await reply
            await bobSilent
            #expect(block.contains("you: Admin"))
            #expect(block.contains("login: admin"))
            #expect(block.contains("admin: true"))
            // UserPrivileges.all expressed as hex; specific value
            // depends on what's defined upstream but this prefix
            // matches the current 41-bit set.
            #expect(block.contains("permissions: 0x1fffff7ffff"))
            #expect(block.contains("tls: no"))
            #expect(block.contains("away: false"))
        }
    }

    @Test("/whoami for a guest shows the guest seed login + admin=false")
    func whoamiAsGuest() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(alice) { $0.contains("permissions:") }
            try await alice.sendChat("/whoami", in: nil, isAction: false)

            let block = try await reply
            #expect(block.contains("you: Alice"))
            #expect(block.contains("login: guest"))
            #expect(block.contains("admin: false"))
            // Guest's seed permissions: 0x18000103e04 — see Account.guestDefaultPermissions.
            #expect(block.contains("permissions: 0x18000103e04"))
        }
    }

    @Test("/uptime is a one-line sender-only reply")
    func uptimeReply() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(alice) { $0.contains("uptime:") }
            try await alice.sendChat("/uptime", in: nil, isAction: false)

            let line = try await reply
            #expect(line.contains("*** uptime:"))
        }
    }

    @Test("/help lists every registered command")
    func helpLists() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            async let reply = Self.awaitChat(alice) { $0.contains("Available commands") }
            try await alice.sendChat("/help", in: nil, isAction: false)

            let block = try await reply
            for expected in ["/version", "/uptime", "/who", "/away", "/me", "/broadcast", "/kick", "/help"] {
                #expect(block.contains(expected), "/help output should list \(expected)")
            }
        }
    }
}
