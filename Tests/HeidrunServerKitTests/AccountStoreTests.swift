import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("AccountStore")
struct AccountStoreTests {
    /// Fast rounds so tests don't burn seconds-per-hash.
    private static let testRounds = 1_000

    private func makeStore() throws -> AccountStore {
        try AccountStore(path: nil, passwordRounds: Self.testRounds)
    }

    @Test("create + get round-trips an account")
    func createAndGet() async throws {
        let store = try makeStore()
        _ = try await store.create(
            login: "alice",
            password: "hunter2",
            nickname: "Alice",
            iconID: 42,
            permissions: AccountPrivilege.disconnectUsers.rawValue
        )
        let fetched = try await store.get(login: "alice")
        #expect(fetched?.login == "alice")
        #expect(fetched?.nickname == "Alice")
        #expect(fetched?.iconID == 42)
        #expect(fetched?.has(.disconnectUsers) == true)
    }

    @Test("create with duplicate login throws loginAlreadyExists")
    func rejectsDuplicateLogin() async throws {
        let store = try makeStore()
        _ = try await store.create(login: "bob", password: "x", nickname: "Bob")
        do {
            _ = try await store.create(login: "bob", password: "y", nickname: "Other Bob")
            #expect(Bool(false), "expected throw")
        } catch AccountStore.AccountStoreError.loginAlreadyExists(let login) {
            #expect(login == "bob")
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("verifyCredentials accepts the right password and rejects the wrong one")
    func verifyCredentials() async throws {
        let store = try makeStore()
        _ = try await store.create(login: "carol", password: "right", nickname: "Carol")
        let valid = try await store.verifyCredentials(login: "carol", password: "right")
        let invalid = try await store.verifyCredentials(login: "carol", password: "wrong")
        let unknown = try await store.verifyCredentials(login: "noone", password: "right")
        #expect(valid?.login == "carol")
        #expect(invalid == nil)
        #expect(unknown == nil)
    }

    @Test("update changes nickname/icon/permissions and optionally the password")
    func updateMutates() async throws {
        let store = try makeStore()
        _ = try await store.create(login: "dave", password: "old", nickname: "Dave")
        let updated = try await store.update(
            login: "dave",
            nickname: "David",
            iconID: 7,
            permissions: AccountPrivilege.modifyAccounts.rawValue,
            newPassword: "new"
        )
        #expect(updated?.nickname == "David")
        #expect(updated?.iconID == 7)
        #expect(updated?.has(.modifyAccounts) == true)
        // Old password should now fail; new one works.
        let oldAttempt = try await store.verifyCredentials(login: "dave", password: "old")
        let newAttempt = try await store.verifyCredentials(login: "dave", password: "new")
        #expect(oldAttempt == nil)
        #expect(newAttempt?.login == "dave")
    }

    @Test("delete removes the row and second delete returns false")
    func deleteRemoves() async throws {
        let store = try makeStore()
        _ = try await store.create(login: "ed", password: "x", nickname: "Ed")
        let firstDelete = try await store.delete(login: "ed")
        let secondDelete = try await store.delete(login: "ed")
        let after = try await store.get(login: "ed")
        #expect(firstDelete == true)
        #expect(secondDelete == false)
        #expect(after == nil)
    }

    @Test("bootstrapIfEmpty seeds an admin only on the first call")
    func bootstrapIsIdempotent() async throws {
        let store = try makeStore()
        let firstSeed = try await store.bootstrapIfEmpty(
            login: "admin",
            password: "admin",
            nickname: "Admin",
            permissions: AccountPrivilege.disconnectUsers.rawValue
        )
        let secondSeed = try await store.bootstrapIfEmpty(
            login: "admin",
            password: "admin",
            nickname: "Admin",
            permissions: AccountPrivilege.disconnectUsers.rawValue
        )
        let count = try await store.count()
        #expect(firstSeed == true)
        #expect(secondSeed == false)
        #expect(count == 1)
    }
}
