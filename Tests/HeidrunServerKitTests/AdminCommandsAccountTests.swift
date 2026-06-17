import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("AdminCommands accounts")
struct AdminCommandsAccountTests {
    private func makeStore() throws -> AccountStore {
        try AccountStore(path: nil, passwordRounds: 4)
    }

    @Test("create then show round-trips, password verifies")
    func createShow() async throws {
        let store = try makeStore()
        let created = try await AdminCommands.create(
            store: store, login: "bob", password: "hunter2",
            nickname: "Bob", permissions: Account.guestDefaultPermissions
        )
        #expect(created.login == "bob")
        let shown = try await AdminCommands.show(store: store, login: "bob")
        #expect(shown.nickname == "Bob")
        #expect(try await store.verifyCredentials(login: "bob", password: "hunter2") != nil)
    }

    @Test("show on a missing login throws accountNotFound")
    func showMissing() async throws {
        let store = try makeStore()
        await #expect(throws: AdminError.accountNotFound("ghost")) {
            try await AdminCommands.show(store: store, login: "ghost")
        }
    }

    @Test("setPassword changes the password")
    func setPassword() async throws {
        let store = try makeStore()
        _ = try await AdminCommands.create(store: store, login: "bob", password: "old", nickname: "Bob", permissions: 0)
        _ = try await AdminCommands.setPassword(store: store, login: "bob", newPassword: "new")
        #expect(try await store.verifyCredentials(login: "bob", password: "old") == nil)
        #expect(try await store.verifyCredentials(login: "bob", password: "new") != nil)
    }

    @Test("rename changes the nickname")
    func rename() async throws {
        let store = try makeStore()
        _ = try await AdminCommands.create(store: store, login: "bob", password: "p", nickname: "Bob", permissions: 0)
        let renamed = try await AdminCommands.rename(store: store, login: "bob", nickname: "Bobby")
        #expect(renamed.nickname == "Bobby")
    }

    @Test("delete removes the account and reports false the second time")
    func delete() async throws {
        let store = try makeStore()
        _ = try await AdminCommands.create(store: store, login: "bob", password: "p", nickname: "Bob", permissions: 0)
        #expect(try await AdminCommands.delete(store: store, login: "bob") == true)
        #expect(try await AdminCommands.delete(store: store, login: "bob") == false)
    }
}
