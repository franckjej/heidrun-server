import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Private chat", .serialized)
struct PrivateChatTests {

    /// Race-safe wait for one matching event from `events`, with a
    /// timeout to keep a stuck test from hanging CI. Returns `nil`
    /// on timeout.
    private static func awaitEvent<T: Sendable>(
        on client: any HotlineClient,
        timeout: Duration = .seconds(2),
        matching: @escaping @Sendable (HotlineEvent) -> T?
    ) async -> T? {
        let collector = Task { () -> T? in
            for await event in client.events {
                if let extracted = matching(event) {
                    return extracted
                }
            }
            return nil
        }
        return await withTaskGroup(of: T?.self) { group in
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
    }

    @Test("createPrivateChat returns a chat reference and pushes an invitation to the target")
    func createPushesInvitation() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let users = try await alice.fetchUserList()
            guard let bobSocket = users.first(where: { $0.nickname == "Bob" })?.socket else {
                Issue.record("Bob not in user list")
                return
            }

            async let inviteEvent = Self.awaitEvent(on: bob) { event -> ChatID? in
                if case let .privateChatInvited(chat, _, _) = event { return chat }
                return nil
            }

            let createdChat = try await alice.createPrivateChat(with: bobSocket)
            let invited = await inviteEvent

            #expect(invited != nil)
            #expect(invited == createdChat)
        }
    }

    @Test("joinPrivateChat broadcasts privateChatJoined to existing members")
    func joinFansOutToExistingMembers() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let users = try await alice.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)

            let chat = try await alice.createPrivateChat(with: bobSocket)
            try await Task.sleep(for: .milliseconds(100))

            async let joinedEvent = Self.awaitEvent(on: alice) { event -> User? in
                if case let .privateChatJoined(_, user) = event, user.nickname == "Bob" {
                    return user
                }
                return nil
            }

            try await bob.joinPrivateChat(chat)
            let joiner = await joinedEvent

            #expect(joiner != nil)
            #expect(joiner?.nickname == "Bob")
        }
    }

    @Test("leavePrivateChat broadcasts privateChatLeft to remaining members")
    func leaveFansOutToRemaining() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let users = try await alice.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)
            let chat = try await alice.createPrivateChat(with: bobSocket)
            try await bob.joinPrivateChat(chat)
            try await Task.sleep(for: .milliseconds(100))

            async let leftEvent = Self.awaitEvent(on: alice) { event -> UInt16? in
                if case let .privateChatLeft(chatRef, socket) = event, chatRef == chat {
                    return socket
                }
                return nil
            }

            try await bob.leavePrivateChat(chat)
            let leftSocket = await leftEvent

            #expect(leftSocket == bobSocket)
        }
    }

    @Test("changeChatSubject broadcasts privateChatSubjectChanged to other members")
    func subjectChangeFansOut() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let users = try await alice.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)
            let chat = try await alice.createPrivateChat(with: bobSocket)
            try await bob.joinPrivateChat(chat)
            try await Task.sleep(for: .milliseconds(100))

            async let subjectEvent = Self.awaitEvent(on: bob) { event -> String? in
                if case let .privateChatSubjectChanged(chatRef, subject) = event, chatRef == chat {
                    return subject
                }
                return nil
            }

            try await alice.changeChatSubject("Spring planning", in: chat)
            let observed = await subjectEvent

            #expect(observed == "Spring planning")
        }
    }

    @Test("invite to an existing chat pushes a 113 to the target")
    func explicitInvite() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            let carol = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Carol")
            try await Task.sleep(for: .milliseconds(200))

            let users = try await alice.fetchUserList()
            let carolSocket = try #require(users.first(where: { $0.nickname == "Carol" })?.socket)
            let chat = try await alice.createPrivateChat(with: 0)  // self-only room
            try await Task.sleep(for: .milliseconds(100))

            async let carolInvite = Self.awaitEvent(on: carol) { event -> ChatID? in
                if case let .privateChatInvited(chatRef, _, _) = event { return chatRef }
                return nil
            }

            try await alice.invite(socket: carolSocket, to: chat)
            let carolSawIt = await carolInvite

            _ = bob  // keep alive
            #expect(carolSawIt == chat)
        }
    }

    @Test("disconnecting a member pushes privateChatLeft to others")
    func disconnectEvictsFromChat() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let users = try await alice.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)
            let chat = try await alice.createPrivateChat(with: bobSocket)
            try await bob.joinPrivateChat(chat)
            try await Task.sleep(for: .milliseconds(100))

            async let leftEvent = Self.awaitEvent(on: alice, timeout: .seconds(3)) { event -> UInt16? in
                if case let .privateChatLeft(chatRef, socket) = event,
                   chatRef == chat,
                   socket == bobSocket {
                    return socket
                }
                return nil
            }

            await bob.disconnect()
            let leftSocket = await leftEvent

            #expect(leftSocket == bobSocket)
        }
    }
}
