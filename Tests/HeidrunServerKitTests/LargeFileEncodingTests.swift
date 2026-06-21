import Testing
import Foundation
import HeidrunCore
@testable import HeidrunServerKit

/// Wire-format coverage for the large-file (64-bit) transfer extension:
/// capability negotiation echo (Task 11), 64-bit size fields on the file
/// list / info / download replies (Task 12), and the 24-byte HTXF
/// handshake + registry round-trips (Task 13).
@Suite("Large-file encoding")
struct LargeFileEncodingTests {
    /// Decode a PacketEncoder reply's body into typed fields.
    private func decodeFields(_ packet: Data) -> [PacketField] {
        PacketCodec.decodeBody(Data(packet.dropFirst(PacketHeader.byteCount)))
    }

    // MARK: - Task 11: capability echo

    @Test("loginReply echoes a non-empty capabilities field (0x01F0)")
    func loginReplyEchoesCapabilities() {
        let reply = PacketEncoder.loginReply(
            taskNumber: 1,
            advertisedVersion: 151,
            socketID: 7,
            serverName: "Heidrun",
            capabilities: [.largeFiles],
            encoding: .macOSRoman
        )
        let fields = decodeFields(reply)
        #expect(fields.uint16(.capabilities) == CapabilityFlags.largeFiles.rawValue)
        #expect(fields.uint16(.capabilities) == 1)
    }

    @Test("loginReply omits the capabilities field when nothing negotiated")
    func loginReplyOmitsCapabilities() {
        let reply = PacketEncoder.loginReply(
            taskNumber: 1,
            advertisedVersion: 151,
            socketID: 7,
            serverName: "Heidrun",
            capabilities: [],
            encoding: .macOSRoman
        )
        let fields = decodeFields(reply)
        #expect(fields.first(.capabilities) == nil)
    }
}
