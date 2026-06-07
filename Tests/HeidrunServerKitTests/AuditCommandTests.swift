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

    @Test("parses --flag value args with defaults and clamps")
    func argParsing() {
        let parsed = ClientSession.parseAuditArgs(["--type", "auth", "--user", "bob", "--since", "7d", "--limit", "999"])
        #expect(parsed.kinds == [.loginOK, .loginFail])
        #expect(parsed.account == "bob")
        #expect(parsed.hours == 7 * 24)
        #expect(parsed.limit == 500)              // clamped from 999
    }

    @Test("--account is an alias for --user; a flag with no value is ignored")
    func argAliasesAndDangling() {
        #expect(ClientSession.parseAuditArgs(["--account", "alice"]).account == "alice")
        // A trailing flag with no value must not crash or consume past the end.
        let parsed = ClientSession.parseAuditArgs(["--type", "admin", "--limit"])
        #expect(Set(parsed.kinds ?? []) == [.accountCreate, .accountModify, .accountDelete, .kick, .broadcast, .topic])
        #expect(parsed.limit == 50)               // dangling --limit left the default
    }

    @Test("defaults: no args → all kinds, 24h, limit 50")
    func argDefaults() {
        let parsed = ClientSession.parseAuditArgs([])
        #expect(parsed.kinds == nil)
        #expect(parsed.account == nil)
        #expect(parsed.hours == 24)
        #expect(parsed.limit == 50)
    }

    @Test("smart-dash-substituted flags (em/en dash) still parse as --flags")
    func smartDashTolerance() {
        // macOS NSTextView "smart dashes" turns "--" into an em/en dash in
        // the chat input, so a typed --type arrives as —type.
        #expect(ClientSession.parseAuditArgs(["\u{2014}type", "auth"]).kinds == [.loginOK, .loginFail])  // em dash
        #expect(ClientSession.parseAuditArgs(["\u{2013}user", "bob"]).account == "bob")                  // en dash
        #expect(ClientSession.auditArgsRequestHelp(["\u{2014}help"]))
    }

    @Test("help tokens are detected, real args are not")
    func helpDetection() {
        #expect(ClientSession.auditArgsRequestHelp(["help"]))
        #expect(ClientSession.auditArgsRequestHelp(["--help"]))
        #expect(ClientSession.auditArgsRequestHelp(["-h"]))
        #expect(ClientSession.auditArgsRequestHelp(["?"]))
        #expect(ClientSession.auditArgsRequestHelp(["type:auth", "HELP"]))  // case-insensitive
        #expect(!ClientSession.auditArgsRequestHelp([]))
        #expect(!ClientSession.auditArgsRequestHelp(["type:auth"]))
    }

    @Test("alias command names imply a default type filter")
    func aliasDefaultType() {
        #expect(ClientSession.defaultAuditType(forCommand: "transfers") == "transfer")
        #expect(ClientSession.defaultAuditType(forCommand: "authlog") == "auth")
        #expect(ClientSession.defaultAuditType(forCommand: "adminlog") == "admin")
        #expect(ClientSession.defaultAuditType(forCommand: "audit") == nil)
    }
}
