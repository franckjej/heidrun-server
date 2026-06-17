import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("AdminFormat")
struct AdminFormatTests {
    private func sampleAccount() -> Account {
        Account(
            id: 1, login: "bob", nickname: "Bob", passwordHash: "PHC-SECRET",
            iconID: 0, permissions: UserPrivileges([.readChat, .sendChat]).rawValue,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("account JSON includes privilege names and excludes the password hash")
    func accountJSON() throws {
        let json = try AdminFormat.json(AdminFormat.accountDTO(sampleAccount()))
        #expect(json.contains("\"login\""))
        #expect(json.contains("readChat"))
        #expect(!json.contains("PHC-SECRET"))
        #expect(!json.lowercased().contains("passwordhash"))
    }

    @Test("account table lists login and nickname, not the hash")
    func accountTable() {
        let table = AdminFormat.accountTable([sampleAccount()])
        #expect(table.contains("bob"))
        #expect(table.contains("Bob"))
        #expect(!table.contains("PHC-SECRET"))
    }
}
