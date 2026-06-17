import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("AdminCommands privileges")
struct AdminCommandsPrivilegesTests {
    private func makeStore() async throws -> AccountStore {
        let store = try AccountStore(path: nil, passwordRounds: 4)
        _ = try await store.create(
            login: "bob", password: "p", nickname: "Bob",
            permissions: UserPrivileges([.readChat, .sendChat]).rawValue
        )
        return store
    }

    @Test("grant adds bits, revoke removes them")
    func grantRevoke() async throws {
        let store = try await makeStore()
        let updated = try await AdminCommands.editPrivileges(
            store: store, login: "bob",
            grant: [.createUser], revoke: [.sendChat], set: nil
        )
        let perms = UserPrivileges(rawValue: updated.permissions)
        #expect(perms.contains(.createUser))
        #expect(perms.contains(.readChat))
        #expect(!perms.contains(.sendChat))
    }

    @Test("set replaces the whole mask")
    func setReplaces() async throws {
        let store = try await makeStore()
        let updated = try await AdminCommands.editPrivileges(
            store: store, login: "bob",
            grant: [], revoke: [], set: [.disconnectUsers]
        )
        #expect(UserPrivileges(rawValue: updated.permissions) == [.disconnectUsers])
    }

    @Test("editing a missing account throws")
    func missing() async throws {
        let store = try await makeStore()
        await #expect(throws: AdminError.accountNotFound("ghost")) {
            try await AdminCommands.editPrivileges(
                store: store, login: "ghost", grant: [.readChat], revoke: [], set: nil
            )
        }
    }
}
