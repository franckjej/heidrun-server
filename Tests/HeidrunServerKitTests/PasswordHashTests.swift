import Foundation
import Testing
@testable import HeidrunServerKit

@Suite("PasswordHash")
struct PasswordHashTests {
    /// Use a tiny round count so tests stay fast — the production
    /// default (210 000) is multiple seconds per hash.
    private static let testRounds = 1_000

    @Test("hash + verify round-trips the same password")
    func roundTrips() throws {
        let phc = try PasswordHash.hash("hunter2", rounds: Self.testRounds)
        #expect(PasswordHash.verify("hunter2", hashedPHC: phc))
    }

    @Test("verify rejects the wrong password")
    func rejectsWrong() throws {
        let phc = try PasswordHash.hash("hunter2", rounds: Self.testRounds)
        #expect(!PasswordHash.verify("hunter3", hashedPHC: phc))
    }

    @Test("two hashes of the same password produce distinct PHC strings (random salt)")
    func uniqueSaltPerHash() throws {
        let first = try PasswordHash.hash("hunter2", rounds: Self.testRounds)
        let second = try PasswordHash.hash("hunter2", rounds: Self.testRounds)
        #expect(first != second)
        #expect(PasswordHash.verify("hunter2", hashedPHC: first))
        #expect(PasswordHash.verify("hunter2", hashedPHC: second))
    }

    @Test("verify rejects a malformed PHC string")
    func rejectsMalformed() {
        #expect(!PasswordHash.verify("anything", hashedPHC: "not-a-phc-string"))
        #expect(!PasswordHash.verify("anything", hashedPHC: "$pbkdf2-sha256$bogus"))
    }
}
