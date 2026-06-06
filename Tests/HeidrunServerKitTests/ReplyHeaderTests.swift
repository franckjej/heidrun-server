import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

/// Vanilla Hotline zeroes a reply's transaction type and correlates by
/// taskNumber; echoing the request type back (e.g. `0x0001_006b` for a
/// login reply) trips strict third-party clients like gtkhx. These tests
/// pin every `PacketEncoder` reply to `classID: 1, transactionID: 0` and
/// confirm pushes still carry their type.
@Suite("Reply header convention")
struct ReplyHeaderTests {
    @Test("every reply builder emits classID 1 with a zero transaction type")
    func repliesZeroTheTransactionType() throws {
        let replies: [(name: String, packet: Data)] = [
            ("loginReply", PacketEncoder.loginReply(
                taskNumber: 42, advertisedVersion: 151, socketID: 7,
                serverName: "Inn", encoding: .macOSRoman)),
            ("emptyReply", PacketEncoder.emptyReply(taskNumber: 42, transactionID: 105)),
            ("errorReply", PacketEncoder.errorReply(
                taskNumber: 42, transactionID: 212, message: "nope")),
            ("userListReply", PacketEncoder.userListReply(
                taskNumber: 42, members: [], encoding: .macOSRoman)),
            ("plainNewsReply", PacketEncoder.plainNewsReply(
                taskNumber: 42, feed: "news", encoding: .macOSRoman)),
            ("fileListReply", PacketEncoder.fileListReply(
                taskNumber: 42, entries: [], encoding: .macOSRoman)),
            ("uploadFileReply", PacketEncoder.uploadFileReply(taskNumber: 42, transferID: 9)),
            ("downloadFileReply", PacketEncoder.downloadFileReply(
                taskNumber: 42, transferID: 9, transferSize: 100))
        ]

        for reply in replies {
            let header = try #require(
                PacketHeader(decoding: reply.packet),
                "\(reply.name) produced an undecodable header")
            #expect(header.classID == 1, "\(reply.name) should be a reply (classID 1)")
            #expect(header.transactionID == 0,
                    "\(reply.name) must zero the reply type, not echo the request")
            #expect(header.taskNumber == 42, "\(reply.name) must echo the taskNumber")
        }
    }

    @Test("pushes keep their transaction type so the client can route them")
    func pushesKeepTheirType() throws {
        let userLeft = PacketEncoder.userLeftPush(socketID: 7)
        let header = try #require(PacketHeader(decoding: userLeft))
        #expect(header.classID == 0)
        #expect(header.transactionID == 302)
    }
}
