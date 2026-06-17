import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("AccountStore.list")
struct AccountStoreListTests {
    // Fast hashing so the test doesn't burn seconds per create.
    private func makeStore() throws -> AccountStore {
        try AccountStore(path: nil, passwordRounds: 4)
    }

    @Test("list returns every account, ordered by login")
    func listsAll() async throws {
        let store = try makeStore()
        _ = try await store.create(login: "carol", password: "p", nickname: "Carol")
        _ = try await store.create(login: "alice", password: "p", nickname: "Alice")
        _ = try await store.create(login: "bob", password: "p", nickname: "Bob")

        let all = try await store.list()

        #expect(all.map(\.login) == ["alice", "bob", "carol"])
    }

    @Test("list is empty for a fresh store")
    func emptyStore() async throws {
        let store = try makeStore()
        #expect(try await store.list().isEmpty)
    }
}
