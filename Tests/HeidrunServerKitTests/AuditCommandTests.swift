import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("Audit command parsing")
struct AuditCommandTests {
    @Test("maps type aliases to kind groups")
    func typeMapping() {
        #expect(ClientSession.auditKinds(forType: "transfer") == [.upload, .download])
        #expect(ClientSession.auditKinds(forType: "auth") == [.loginOK, .loginFail])
        #expect(Set(ClientSession.auditKinds(forType: "admin")!) ==
                [.accountCreate, .accountModify, .accountDelete, .kick, .broadcast, .topic])
        #expect(ClientSession.auditKinds(forType: "presence") == [.join, .leave])
        #expect(ClientSession.auditKinds(forType: "bogus") == nil)
    }

    @Test("parses key:value args with defaults and clamps")
    func argParsing() {
        let parsed = ClientSession.parseAuditArgs(["type:auth", "user:bob", "since:7d", "limit:999"])
        #expect(parsed.kinds == [.loginOK, .loginFail])
        #expect(parsed.account == "bob")
        #expect(parsed.hours == 7 * 24)
        #expect(parsed.limit == 500)              // clamped from 999
    }

    @Test("defaults: no args → all kinds, 24h, limit 50")
    func argDefaults() {
        let parsed = ClientSession.parseAuditArgs([])
        #expect(parsed.kinds == nil)
        #expect(parsed.account == nil)
        #expect(parsed.hours == 24)
        #expect(parsed.limit == 50)
    }

    @Test("alias command names imply a default type filter")
    func aliasDefaultType() {
        #expect(ClientSession.defaultAuditType(forCommand: "transfers") == "transfer")
        #expect(ClientSession.defaultAuditType(forCommand: "authlog") == "auth")
        #expect(ClientSession.defaultAuditType(forCommand: "adminlog") == "admin")
        #expect(ClientSession.defaultAuditType(forCommand: "audit") == nil)
    }
}
