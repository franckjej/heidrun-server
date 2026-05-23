import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Idle-away supervisor", .serialized)
struct IdleAwayTests {

    /// Wait up to `timeout` for the first userChanged event on `client`
    /// matching `predicate`. Returns the user or throws on timeout.
    private static func awaitUserChanged(
        _ client: any HotlineClient,
        timeout: Duration,
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
                domain: "IdleAwayTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for matching userChanged"]
            )
        }
        return captured
    }

    @Test("supervisor flips a quiet session to away once the threshold elapses")
    func supervisorFiresAfterThreshold() async throws {
        // Short threshold + short poll so the test wraps in a few
        // seconds. Default values (600s threshold, 60s poll) would be
        // impractical for an integration test.
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            idleAwayThreshold: 1.0,
            idleAwayPollInterval: 0.3
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            // Alice does nothing. Within a few poll cycles, the
            // supervisor should mark her away and bob should observe
            // the userChanged broadcast.
            let observed = try await Self.awaitUserChanged(bob, timeout: .seconds(3)) {
                $0.nickname == "Alice" && $0.status.flags.contains(.away)
            }
            #expect(observed.status.flags.contains(.away))
        }
    }

    @Test("client pings do not reset the idle clock")
    func pingsDoNotResetIdle() async throws {
        // Same short-threshold setup. Alice sends pings every 200ms;
        // if pings counted as activity, the supervisor would never
        // see her cross the 1.0s threshold. With the fix, pings are
        // ignored and the supervisor flips her to away as it does
        // for a fully idle session.
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            idleAwayThreshold: 1.0,
            idleAwayPollInterval: 0.3
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            // Background pinger.
            let pingerStop = Task { @Sendable in
                while !Task.isCancelled {
                    try? await alice.sendPing()
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { pingerStop.cancel() }

            let observed = try await Self.awaitUserChanged(bob, timeout: .seconds(3)) {
                $0.nickname == "Alice" && $0.status.flags.contains(.away)
            }
            pingerStop.cancel()
            #expect(observed.status.flags.contains(.away))
        }
    }

    @Test("real chat activity DOES reset the idle clock")
    func chatResetsIdle() async throws {
        // Regression check: the fix only filters transID 500 pings.
        // Any other inbound packet — chat in particular — must still
        // bump lastActivityAt so a chatting user doesn't accidentally
        // get marked away.
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            idleAwayThreshold: 1.0,
            idleAwayPollInterval: 0.3
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            // Alice chats every 400ms for ~1.5s — comfortably under
            // the 1.0s threshold per chat, so she should stay
            // not-away the whole time.
            let chatter = Task { @Sendable in
                for index in 0..<4 where !Task.isCancelled {
                    try? await alice.sendChat("ping \(index)", in: nil, isAction: false)
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }

            // Collect userChanged events for Alice during the window
            // and assert none of them set the away flag.
            let observer = Task { () -> Bool in
                for await event in bob.events {
                    if case let .userChanged(user) = event,
                       user.nickname == "Alice",
                       user.status.flags.contains(.away) {
                        return true
                    }
                }
                return false
            }

            try await Task.sleep(for: .seconds(1.6))
            chatter.cancel()
            observer.cancel()

            let sawAway = await observer.value
            #expect(sawAway == false, "chatting user should not be flipped to away")
        }
    }
}
