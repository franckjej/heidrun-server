import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("AdminCommands audit/news/db")
struct AdminCommandsMiscTests {
    @Test("auditEvents filters by kind and respects the window")
    func auditQuery() async throws {
        let log = try AuditLog(path: nil, retentionDays: 90)
        await log.record(AuditEvent(
            timestamp: Date(), kind: .loginOK, account: "bob", nickname: "Bob",
            socket: 1, ip: nil, target: nil, bytes: nil, result: nil, detail: nil))
        await log.record(AuditEvent(
            timestamp: Date(), kind: .join, account: "bob", nickname: "Bob",
            socket: 1, ip: nil, target: nil, bytes: nil, result: nil, detail: nil))

        let auth = await AdminCommands.auditEvents(
            log: log, kinds: [.loginOK, .loginFail], account: nil, hours: 24, limit: 100)
        #expect(auth.count == 1)
        #expect(auth.first?.kind == .loginOK)
    }

    @Test("resetNews clears the persisted news snapshot")
    func newsReset() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("heidrun-admin-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let newsPath = dir.appendingPathComponent("server.news.json").path

        // Seed one plain post via a NewsTree at that path.
        let seeded = NewsTree(persistencePath: newsPath)
        await seeded.appendPlainPost("hello world")
        #expect(await seeded.plainFeed().contains("hello world"))

        await AdminCommands.resetNews(path: newsPath, scope: .all)

        // A fresh NewsTree loading the same file sees the wiped snapshot.
        let reloaded = NewsTree(persistencePath: newsPath)
        #expect(await reloaded.plainFeed().isEmpty)
    }

    @Test("dbInfo reports the account count and configured paths")
    func dbInfo() async throws {
        let store = try AccountStore(path: nil, passwordRounds: 4)
        _ = try await store.create(login: "bob", password: "p", nickname: "Bob")
        let config = ServerConfiguration(newsMode: .threaded, accountStorePath: "/tmp/server.sqlite")
        let info = try await AdminCommands.dbInfo(store: store, configuration: config)
        #expect(info.accountCount == 1)
        #expect(info.accountStorePath == "/tmp/server.sqlite")
        #expect(info.newsMode == "threaded")
    }
}
