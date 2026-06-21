import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("UnifiedLogTableFormatter")
struct UnifiedLogTableTests {
    private func opDispatch(transID: String) -> UnifiedLogRecord {
        UnifiedLogRecord(op: NDJSONLogRecord(
            timestampMillis: 1_700_000, level: "debug", label: "t", message: "dispatch",
            metadata: ["transID": transID, "taskNumber": "3", "socketID": "42",
                       "nickname": "silver", "login": "silver_box", "isAdmin": "true",
                       "tls": "false", "fieldCount": "5", "remoteHost": "203.0.113.7"],
            source: "t"))
    }

    @Test("header lists the columns including ACTION")
    func header() {
        let header = UnifiedLogTableFormatter.header()
        for title in ["TIME", "S", "LVL", "HOST", "NICK", "ACCOUNT", "ADMIN",
                      "TLS", "TRANS", "SOCK", "TASK", "FLDS", "ACTION"] {
            #expect(header.contains(title))
        }
    }

    @Test("ACCOUNT shows the login; ADMIN renders a compact marker")
    func accountAndAdmin() {
        let adminRow = UnifiedLogTableFormatter.row(opDispatch(transID: "107"))
        #expect(adminRow.contains("silver_box"))   // ACCOUNT = login
        #expect(adminRow.contains("yes"))           // ADMIN compact marker (isAdmin=true)

        let nonAdmin = UnifiedLogRecord(op: NDJSONLogRecord(
            timestampMillis: 1_700_000, level: "info", label: "t", message: "dispatch",
            metadata: ["transID": "300", "login": "guest", "isAdmin": "false"], source: "t"))
        let nonAdminRow = UnifiedLogTableFormatter.row(nonAdmin)
        #expect(nonAdminRow.contains("guest"))      // ACCOUNT
        #expect(!nonAdminRow.contains("yes"))       // ADMIN blank for non-admins
    }

    @Test("a dispatch row resolves transID to the transaction name in ACTION")
    func dispatchResolvesName() {
        let row = UnifiedLogTableFormatter.row(opDispatch(transID: "107"))
        #expect(row.contains("203.0.113.7"))   // HOST
        #expect(row.contains("silver"))         // NICK
        #expect(row.contains("107"))            // TRANS (raw number kept)
        #expect(row.contains("42"))             // SOCK
        #expect(row.hasSuffix("login"))         // ACTION = resolved name, last column
    }

    @Test("an unknown transID falls back to txn <id> in ACTION")
    func unknownTransID() {
        let row = UnifiedLogTableFormatter.row(opDispatch(transID: "9999"))
        #expect(row.hasSuffix("txn 9999"))
    }

    @Test("a non-dispatch op row shows its message verbatim in ACTION")
    func nonDispatchMessage() {
        let record = UnifiedLogRecord(op: NDJSONLogRecord(
            timestampMillis: 1_700_000, level: "info", label: "t",
            message: "connection accepted",
            metadata: ["remoteHost": "203.0.113.7", "tls": "false"], source: "t"))
        let row = UnifiedLogTableFormatter.row(record)
        #expect(row.hasSuffix("connection accepted"))
    }

    @Test("an audit row shows '—' for LVL, account for NICK, text for ACTION")
    func auditRow() {
        let record = UnifiedLogRecord(
            timestampMillis: 1_700_000, source: .audit, tag: "join",
            text: "alice → #general", account: "alice")
        let row = UnifiedLogTableFormatter.row(record)
        #expect(row.contains("a "))             // source marker
        #expect(row.contains("—"))              // LVL placeholder
        #expect(row.contains("alice"))          // NICK (from account) + ACTION
        #expect(row.hasSuffix("alice → #general"))
    }

    @Test("an over-long fixed column is truncated with an ellipsis")
    func truncatesLongHost() {
        let record = UnifiedLogRecord(
            timestampMillis: 1_700_000, source: .op, tag: "info",
            text: "x", account: nil,
            metadata: ["remoteHost": "2001:0db8:0000:0000:0000:ff00:0042:8329:65535"])
        let row = UnifiedLogTableFormatter.row(record)
        #expect(row.contains("…"))
    }

    @Test("withDate switches the timestamp column to a full date")
    func withDateColumn() {
        let header = UnifiedLogTableFormatter.header(withDate: true)
        #expect(header.contains("TIMESTAMP"))
        let row = UnifiedLogTableFormatter.row(opDispatch(transID: "107"), withDate: true)
        #expect(row.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil)
    }

    @Test("the default timestamp column is time-of-day only")
    func defaultTimeOnly() {
        let row = UnifiedLogTableFormatter.row(opDispatch(transID: "107"))
        #expect(row.range(of: #"^\d{2}:\d{2}:\d{2} "#, options: .regularExpression) != nil)
        #expect(UnifiedLogTableFormatter.header().contains("TIME "))
    }

    @Test("rows joins records with newlines and excludes the header")
    func rowsJoin() {
        let text = UnifiedLogTableFormatter.rows([opDispatch(transID: "107"), opDispatch(transID: "300")])
        #expect(text.split(separator: "\n").count == 2)
        #expect(!text.contains("TIME"))
    }
}
