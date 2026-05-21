import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Private messages", .serialized)
struct PrivateMessageTests {
    @Test("PM routes from sender to target and shows up in the target's events")
    func privateMessageRoutes() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(200))

            let users = try await alice.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)

            let observer = Task { () -> String? in
                for await event in bob.events {
                    if case let .messageReceived(_, message) = event, message.contains("hi") {
                        return message
                    }
                }
                return nil
            }

            try await alice.sendPrivateMessage("hi", to: bobSocket)

            let received: String? = try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw NSError(domain: "PrivateMessageTests", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "PM not received"
                    ])
                }
                group.addTask { _ = await observer.value }
                try await group.next()
                group.cancelAll()
                return await observer.value
            }

            #expect(received?.contains("hi") == true)
        }
    }
}
