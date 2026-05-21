import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Kick", .serialized)
struct KickTests {
    private static let testRounds = 1_000

    @Test("kick disconnects the target and remaining users see userLeft")
    func kickDisconnectsTarget() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            accountStorePath: nil,
            passwordRounds: Self.testRounds,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "alice",
                password: "hunter2",
                nickname: "Alice"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Alice",
                loginName: "alice",
                password: "hunter2"
            )
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(200))

            let users = try await alice.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)

            let observer = Task { () -> UInt16? in
                for await event in alice.events {
                    if case let .userLeft(socket) = event {
                        return socket
                    }
                }
                return nil
            }

            try await alice.kick(socket: bobSocket, ban: false)

            let leftSocket: UInt16? = try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw NSError(domain: "KickTests", code: 0)
                }
                group.addTask { _ = await observer.value }
                try await group.next()
                group.cancelAll()
                return await observer.value
            }

            #expect(leftSocket == bobSocket)
            _ = bob
        }
    }

    @Test("guest kick attempt fails — disconnectUsers privilege required")
    func guestCannotKick() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(200))

            let users = try await alice.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)

            do {
                try await alice.kick(socket: bobSocket, ban: false)
                #expect(Bool(false), "expected kick to throw for guest")
            } catch {
                // expected — server replies errorID=1
            }
            // Bob still online; user list unchanged.
            let afterKick = try await alice.fetchUserList()
            #expect(afterKick.contains(where: { $0.nickname == "Bob" }))
            _ = bob
        }
    }
}
