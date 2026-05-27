import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("setClientUserInfo (304)", .serialized)
struct NicknameChangeTests {

    @Test("other clients see userChanged with the new nickname/icon")
    func userChangedFansOut() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let observer = Task { () -> User? in
                for await event in alice.events {
                    if case let .userChanged(user) = event, user.nickname == "Roberta" {
                        return user
                    }
                }
                return nil
            }

            try await bob.changeNickname("Roberta", icon: 4242, emoji: nil, persist: false)

            let observed: User? = await withTaskGroup(of: User?.self) { group in
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    observer.cancel()
                    return nil
                }
                group.addTask { await observer.value }
                let value = (await group.next()).flatMap { $0 }
                group.cancelAll()
                return value
            }

            #expect(observed?.nickname == "Roberta")
            #expect(observed?.icon == 4242)

            // Roster reflects the change for future fetches too.
            let users = try await alice.fetchUserList()
            #expect(users.contains { $0.nickname == "Roberta" && $0.icon == 4242 })
        }
    }
}

@Suite("broadcast (355)", .serialized)
struct BroadcastTests {

    @Test("authenticated admin can broadcast and others receive the message")
    func adminBroadcastReaches() async throws {
        try await ServerTestHelpers.withRunningServer(
            configuration: ServerConfiguration(
                port: 0,
                bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                    login: "admin",
                    password: "admin",
                    nickname: "Admin"
                )
            )
        ) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let observer = Task { () -> String? in
                for await event in bob.events {
                    if case let .broadcastReceived(message) = event { return message }
                }
                return nil
            }

            try await admin.broadcast("Server going down at midnight")

            let received: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    observer.cancel()
                    return nil
                }
                group.addTask { await observer.value }
                let value = (await group.next()).flatMap { $0 }
                group.cancelAll()
                return value
            }

            #expect(received == "Server going down at midnight")
        }
    }

    @Test("guest without canBroadcast gets an error reply")
    func guestBroadcastRejected() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let guest = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Guest")
            try await Task.sleep(for: .milliseconds(100))

            await #expect(throws: (any Error).self) {
                try await guest.broadcast("I shouldn't be able to do this")
            }
        }
    }
}

@Suite("news delete (380 / 411)", .serialized)
struct NewsDeleteTests {

    @Test("createNewsBundle followed by deleteNewsBundle removes it from fetchNewsBundles")
    func bundleRoundTrip() async throws {
        try await ServerTestHelpers.withRunningServer(
            configuration: ServerConfiguration(
                port: 0,
                bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                    login: "admin",
                    password: "admin",
                    nickname: "Admin"
                )
            )
        ) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )

            try await admin.createNewsBundle(at: RemotePath(), name: "Announcements", isCategory: false)
            try await Task.sleep(for: .milliseconds(50))
            let afterCreate = try await admin.fetchNewsBundles(at: RemotePath())
            #expect(afterCreate.contains { $0.title == "Announcements" })

            try await admin.deleteNewsBundle(at: RemotePath(components: ["Announcements"]))
            try await Task.sleep(for: .milliseconds(50))
            let afterDelete = try await admin.fetchNewsBundles(at: RemotePath())
            #expect(!afterDelete.contains { $0.title == "Announcements" })
        }
    }

    @Test("posting then deleting a news thread leaves the category empty")
    func threadRoundTrip() async throws {
        try await ServerTestHelpers.withRunningServer(
            configuration: ServerConfiguration(
                port: 0,
                bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                    login: "admin",
                    password: "admin",
                    nickname: "Admin"
                )
            )
        ) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )

            try await admin.createNewsBundle(at: RemotePath(), name: "Topics", isCategory: true)
            let topicsPath = RemotePath(components: ["Topics"])
            try await admin.postNewsThread(
                at: topicsPath,
                parentThreadID: 0,
                title: "Hello",
                type: "application/x-trh-mime-text",
                body: "first post"
            )
            try await Task.sleep(for: .milliseconds(50))

            let beforeDelete = try await admin.fetchNewsThreads(at: topicsPath)
            #expect(beforeDelete.count == 1)
            let articleID = try #require(beforeDelete.first?.threadID)

            try await admin.deleteNewsThread(at: topicsPath, threadID: articleID, cascade: false)
            try await Task.sleep(for: .milliseconds(50))
            let afterDelete = try await admin.fetchNewsThreads(at: topicsPath)
            #expect(afterDelete.isEmpty)
        }
    }
}

@Suite("ping (500)", .serialized)
struct PingTests {

    @Test("sendPing does not close the connection and the session keeps working")
    func pingPreservesSession() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Pinger")
            try await Task.sleep(for: .milliseconds(100))

            try await client.sendPing()
            try await Task.sleep(for: .milliseconds(50))

            // Issuing a follow-up transaction proves the dispatch loop
            // didn't fall over on the (no-handler) ping.
            let users = try await client.fetchUserList()
            #expect(users.contains { $0.nickname == "Pinger" })
        }
    }
}
