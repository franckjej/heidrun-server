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
    private static func awaitChat(
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
    private static func expectNoChat(
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
    private static func awaitBroadcast(
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

    /// Assert `client` receives NO broadcast (355) within `timeout`.
    private static func expectNoBroadcast(
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
    private static func awaitUserChanged(
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
            async let adminBroadcast = Self.awaitBroadcast(admin)
            async let adminConfirm = Self.awaitChat(admin) { $0.contains("Broadcast sent") }

            try await admin.sendChat("/broadcast server going down at midnight", in: nil, isAction: false)

            let bobReceived = try await bobBroadcast
            let adminReceived = try await adminBroadcast
            let confirmation = try await adminConfirm

            #expect(bobReceived == "server going down at midnight")
            // Sender included so the operator sees their own message
            // as confirmation it landed via the same channel.
            #expect(adminReceived == "server going down at midnight")
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
}
