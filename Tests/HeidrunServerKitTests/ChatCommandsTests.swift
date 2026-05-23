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
