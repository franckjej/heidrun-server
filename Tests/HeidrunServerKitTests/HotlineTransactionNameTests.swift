import Testing
@testable import HeidrunServerKit

@Suite("HotlineTransactionName")
struct HotlineTransactionNameTests {
    @Test("maps representative dispatched wire IDs to names")
    func knownIDs() {
        #expect(HotlineTransactionName.name(for: 107) == "login")
        #expect(HotlineTransactionName.name(for: 300) == "getUserNameList")
        #expect(HotlineTransactionName.name(for: 105) == "sendChat")
        #expect(HotlineTransactionName.name(for: 202) == "downloadFile")
        #expect(HotlineTransactionName.name(for: 350) == "createAccount")
        #expect(HotlineTransactionName.name(for: 500) == "ping")
    }

    @Test("undispatched / unknown IDs return nil")
    func unknownIDs() {
        // 354 (getUserAccess) is a server→client push, never dispatched in.
        #expect(HotlineTransactionName.name(for: 354) == nil)
        #expect(HotlineTransactionName.name(for: 9999) == nil)
    }
}
