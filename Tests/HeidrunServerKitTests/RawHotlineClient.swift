import Foundation
import Network
import HeidrunCore

/// Minimal wire-level Hotline client for tests that must control every
/// login field — e.g. a classic client that never sends the Heidrun
/// `resourceForkSupport` flag. Speaks the handshake, login, one
/// transaction at a time, and the HTXF side channel.
final class RawHotlineClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RawHotlineClient")
    private let port: UInt16
    private var nextTask: UInt32 = 1

    private init(connection: NWConnection, port: UInt16) {
        self.connection = connection
        self.port = port
    }

    static func connect(port: UInt16) async throws -> RawHotlineClient {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let client = RawHotlineClient(connection: connection, port: port)
        try await connection.startAndWaitForReady(on: client.queue)
        try await connection.sendAsync(Data([
            0x54, 0x52, 0x54, 0x50, 0x48, 0x4F, 0x54, 0x4C,   // "TRTPHOTL"
            0x00, 0x01, 0x00, 0x02
        ]))
        _ = try await connection.receiveExactly(8)
        return client
    }

    /// Classic login: name, password, nickname, icon, version — no 0xE002.
    func loginClassic(nickname: String) async throws -> [PacketField] {
        try await send(transactionID: 107, fields: [
            .obfuscatedString(.login, "", encoding: .macOSRoman),
            .obfuscatedString(.password, "", encoding: .macOSRoman),
            .string(.nickname, nickname, encoding: .macOSRoman),
            .uint16(.icon, 1),
            .uint16(.clientVersion, 151)
        ])
    }

    /// Send one transaction and wait for its reply, skipping server pushes.
    func send(transactionID: UInt16, fields: [PacketField]) async throws -> [PacketField] {
        let taskNumber = nextTask
        nextTask += 1
        try await connection.sendAsync(PacketCodec.encode(
            classID: 0, transactionID: transactionID, taskNumber: taskNumber, errorID: 0, fields: fields
        ))
        while true {
            let headerBytes = try await connection.receiveExactly(PacketHeader.byteCount)
            guard let header = PacketHeader(decoding: headerBytes) else {
                throw HotlineError.malformedReply(reason: "short header")
            }
            let body = header.dataLength > 0 ? try await connection.receiveExactly(Int(header.dataLength)) : Data()
            guard header.classID == 1, header.taskNumber == taskNumber else { continue }
            guard header.errorID == 0 else {
                throw HotlineError.malformedReply(reason: "server error \(header.errorID)")
            }
            return PacketCodec.decodeBody(body)
        }
    }

    /// Open the HTXF side channel for `transferID` and read `count` bytes.
    func readTransfer(transferID: UInt32, count: Int) async throws -> Data {
        let side = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port + 1)!,
            using: .tcp
        )
        try await side.startAndWaitForReady(on: queue)
        defer { side.cancel() }
        try await side.sendAsync(TransferHandshake.encode(transferID: transferID, transferSize: 0))
        return try await side.receiveExactly(count)
    }

    func close() { connection.cancel() }
}
