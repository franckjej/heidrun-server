import Testing
@testable import HeidrunServerKit

@Suite("AuditQueryParsing")
struct AuditQueryParsingTests {
    @Test("type keyword maps to grouped kinds")
    func typeKeywords() {
        #expect(AuditQueryParsing.kinds(forTypeKeyword: "transfer") == [.upload, .download])
        #expect(AuditQueryParsing.kinds(forTypeKeyword: "auth") == [.loginOK, .loginFail])
        #expect(AuditQueryParsing.kinds(forTypeKeyword: "presence") == [.join, .leave])
        #expect(AuditQueryParsing.kinds(forTypeKeyword: "admin")
                == [.accountCreate, .accountModify, .accountDelete, .kick, .broadcast, .topic])
    }

    @Test("a single raw kind name maps to that one kind")
    func singleKind() {
        #expect(AuditQueryParsing.kinds(forTypeKeyword: "kick") == [.kick])
    }

    @Test("unknown type keyword yields nil")
    func unknownKeyword() {
        #expect(AuditQueryParsing.kinds(forTypeKeyword: "nope") == nil)
    }

    @Test("since parses Nh, Nd, and a bare number as hours")
    func since() {
        #expect(AuditQueryParsing.hours(fromSince: "12h") == 12)
        #expect(AuditQueryParsing.hours(fromSince: "7d") == 168)
        #expect(AuditQueryParsing.hours(fromSince: "48") == 48)
        #expect(AuditQueryParsing.hours(fromSince: "garbage") == nil)
    }
}
