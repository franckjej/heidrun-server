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

@Suite("news mutation replies (380 / 381 / 382 / 411)", .serialized)
struct NewsMutationReplyTests {

    private static let configuration = ServerConfiguration(
        port: 0,
        bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
            login: "admin", password: "admin", nickname: "Admin"
        )
    )

    /// Connect + login as admin with a `PacketObserver` recording every
    /// inbound packet, then settle so the post-login pushes land. Returns
    /// the live client and its recorder.
    private static func loginRecording(port: UInt16) async throws
        -> (client: any HotlineClient, recorder: PacketRecorder) {
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
        return (client, recorder)
    }

    @Test("createNewsBundle (381) draws a reply — the server must not stay silent")
    func createBundleReplies() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let (client, recorder) = try await Self.loginRecording(port: port)
            let before = await recorder.replies().count

            try await client.createNewsBundle(at: RemotePath(), name: "Announcements", isCategory: false)
            try await Task.sleep(for: .milliseconds(200))

            let after = await recorder.replies().count
            #expect(after > before, "server must reply to createNewsBundle (381), like mhxd's rcv_news_mkdir")
            await client.disconnect()
        }
    }

    @Test("createNewsCategory (382) draws a reply")
    func createCategoryReplies() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let (client, recorder) = try await Self.loginRecording(port: port)
            let before = await recorder.replies().count

            try await client.createNewsBundle(at: RemotePath(), name: "Topics", isCategory: true)
            try await Task.sleep(for: .milliseconds(200))

            let after = await recorder.replies().count
            #expect(after > before, "server must reply to createNewsCategory (382), like mhxd's rcv_news_mkcategory")
            await client.disconnect()
        }
    }

    @Test("deleteNewsBundle (380) draws a reply")
    func deleteBundleReplies() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let (client, recorder) = try await Self.loginRecording(port: port)
            try await client.createNewsBundle(at: RemotePath(), name: "Scratch", isCategory: false)
            try await Task.sleep(for: .milliseconds(100))
            let before = await recorder.replies().count

            try await client.deleteNewsBundle(at: RemotePath(components: ["Scratch"]))
            try await Task.sleep(for: .milliseconds(200))

            let after = await recorder.replies().count
            #expect(after > before, "server must reply to deleteNewsBundle (380), like mhxd's rcv_news_delete")
            await client.disconnect()
        }
    }

    @Test("deleteNewsThread (411) draws a reply")
    func deleteThreadReplies() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let (client, recorder) = try await Self.loginRecording(port: port)
            try await client.createNewsBundle(at: RemotePath(), name: "Board", isCategory: true)
            let boardPath = RemotePath(components: ["Board"])
            try await client.postNewsThread(
                at: boardPath, parentThreadID: 0, title: "First",
                type: "application/x-trh-mime-text", body: "hi")
            try await Task.sleep(for: .milliseconds(100))
            let threads = try await client.fetchNewsThreads(at: boardPath)
            let articleID = try #require(threads.first?.threadID)
            let before = await recorder.replies().count

            try await client.deleteNewsThread(at: boardPath, threadID: articleID, cascade: false)
            try await Task.sleep(for: .milliseconds(200))

            let after = await recorder.replies().count
            #expect(after > before, "server must reply to deleteNewsThread (411), like mhxd's rcv_news_delete_thread")
            await client.disconnect()
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
