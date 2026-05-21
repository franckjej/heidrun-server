import Foundation

/// Pure-function Hotline handshake. The protocol opens with a fixed
/// 12-byte client magic the server must read in full before any
/// transaction framing kicks in. The server's reply is always 8 bytes:
/// 4 of "TRTP" plus a UInt32 error code (0 = success).
enum Handshake {
    enum Error: Swift.Error, Equatable {
        case truncated
        case badMagic
    }

    /// Parse a 12-byte client handshake and return the 8-byte server
    /// ack to write back. Version and sub-version bytes after the magic
    /// are read but not validated — Hotline 1.x and the various clones
    /// vary too widely for a strict check to be useful here.
    static func parse(_ inbound: Data) throws -> Data {
        guard inbound.count >= 12 else { throw Error.truncated }
        let magic = inbound.prefix(8)
        let expected = Data([0x54, 0x52, 0x54, 0x50, 0x48, 0x4F, 0x54, 0x4C])
        guard magic == expected else { throw Error.badMagic }
        return Data([
            0x54, 0x52, 0x54, 0x50,
            0x00, 0x00, 0x00, 0x00
        ])
    }
}
