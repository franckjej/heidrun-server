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

    // MARK: - Task 12: 64-bit sizes

    @Test("fileListReply(largeFile:) interleaves fileListEntry + fileSize64")
    func fileListReplyLargeFileInterleaves() {
        let bigSize: UInt64 = 0x1_0000_0000 // 4 GiB — overflows UInt32
        let entry = FileVault.Entry(
            name: "huge.bin",
            type: .file,
            creator: .unknown,
            size: bigSize
        )
        let reply = PacketEncoder.fileListReply(
            taskNumber: 1,
            entries: [entry],
            largeFile: true,
            encoding: .macOSRoman
        )
        let fields = decodeFields(reply)
        // Two fields per entry: [fileListEntry, fileSize64].
        #expect(fields.count == 2)
        #expect(fields[0].key == HotlineObjectKey.fileListEntry.rawValue)
        #expect(fields[1].key == HotlineObjectKey.fileSize64.rawValue)
        #expect(fields.uint64(.fileSize64) == bigSize)
        // Decoding the whole list back yields the true 64-bit size.
        let decoded = FileListEntryCodec.decodeList(fields: fields)
        #expect(decoded.first?.size == bigSize)
    }

    @Test("fileListReply without largeFile emits one legacy entry per file")
    func fileListReplyLegacyShape() {
        let entry = FileVault.Entry(name: "small.txt", type: .file, creator: .unknown, size: 42)
        let reply = PacketEncoder.fileListReply(
            taskNumber: 1,
            entries: [entry],
            encoding: .macOSRoman
        )
        let fields = decodeFields(reply)
        #expect(fields.count == 1)
        #expect(fields[0].key == HotlineObjectKey.fileListEntry.rawValue)
        #expect(fields.first(.fileSize64) == nil)
    }

    @Test("downloadFileReply(size64:) appends xferSize64 and clamps the legacy size")
    func downloadFileReplyLargeSize() {
        let bigSize: UInt64 = 0x1_0000_0000
        let reply = PacketEncoder.downloadFileReply(
            taskNumber: 1,
            transferID: 9,
            transferSize: 0,
            size64: bigSize
        )
        let fields = decodeFields(reply)
        #expect(fields.uint64(.xferSize64) == bigSize)
        // Legacy 32-bit transferSize clamps to UInt32.max.
        #expect(fields.uint32(.transferSize) == UInt32.max)
    }

    @Test("downloadFileReply without size64 keeps the legacy 32-bit transferSize only")
    func downloadFileReplyLegacy() {
        let reply = PacketEncoder.downloadFileReply(
            taskNumber: 1,
            transferID: 9,
            transferSize: 1234
        )
        let fields = decodeFields(reply)
        #expect(fields.uint32(.transferSize) == 1234)
        #expect(fields.first(.xferSize64) == nil)
    }
}
