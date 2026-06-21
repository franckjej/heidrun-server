import Foundation
import HeidrunCore
import NIOCore

/// Server-side driver for one folder-download HTXF stream.
///
/// The 16-byte HTXF preamble is read by the caller in
/// `HeidrunServer.runTransferChannel`; this helper takes over after
/// the 18-byte folder handshake (the extra `UInt16 3` sentinel) is
/// consumed. For each enumerated item the helper:
///
///   1. Sends `UInt16 folderHeaderSize + body` (the per-item header).
///   2. Reads `UInt16 action` back from the client:
///        * 1 = download — server sends the per-item payload.
///        * 2 = resume   — server reads the 74-byte RFLT blob and then
///                         streams the same payload (resume offset is
///                         ignored — we don't preserve partial state).
///        * 3 = skip     — server moves to the next item.
///   3. For files only, sends the per-item payload (UInt32 itemFileSize
///      followed by FILP + INFO + DATA + MACR via `UploadFraming`).
///   4. After every item is processed, sends `UInt16 0` to signal EOF.
///
/// The whole exchange is best-effort: any I/O failure cancels the
/// stream and the connection is torn down by the caller.
enum ServerFolderDownload {

    static func drive(
        stream: inout ByteStream<AsyncStream<Data>>,
        outChannel: any Channel,
        items: [FileVault.FolderItem],
        largeFile: Bool,
        encoding: String.Encoding
    ) async {
        // 18-byte handshake: consume the trailing `UInt16 3` sentinel
        // that the client appends after the standard 16-byte HTXF.
        guard (try? await stream.receiveExactly(2)) != nil else { return }

        for item in items {
            let header = encodeItemHeader(
                relativePath: item.relativePath,
                isDirectory: item.isDirectory,
                encoding: encoding
            )
            do {
                try await send(bytes: header, on: outChannel)
            } catch {
                return
            }

            guard let actionBytes = try? await stream.receiveExactly(2) else { return }
            let action = readUInt16(actionBytes)

            if action == 2 {
                // Resume: drain the 74-byte RFLT blob the client sends
                // before we stream the payload. We ignore the contents
                // (no partial-state tracking on the server side yet),
                // so the receive serves only to advance the stream.
                guard (try? await stream.receiveExactly(74)) != nil else { return }
            }

            if item.isDirectory {
                // Action for a directory should be 3 (skip) — nothing
                // to do regardless.
                continue
            }
            if action == 3 {
                continue
            }

            // Build per-item payload: itemFileSize prefix + framed envelope.
            // The prefix is 8 bytes (UInt64) on a large-file session, else
            // the legacy 4 bytes (UInt32) — byte-identical to the historical
            // form for ≤4 GiB items.
            let fileName = item.relativePath.last ?? ""
            let nameBytes = fileName.data(using: encoding, allowLossyConversion: true) ?? Data()
            let total = UploadFraming.totalSize(
                nameLength: nameBytes.count,
                dataLength: UInt64(item.data.count),
                resourceLength: UInt64(item.resourceFork.count)
            )
            let sizePrefix = FolderUploadFraming.encodeItemSizePrefix(total, largeFile: largeFile)
            let framed = UploadFraming.encode(
                fileName: fileName,
                type: item.type,
                creator: item.creator,
                creationDate: item.created,
                modificationDate: item.modified,
                data: item.data,
                resourceFork: item.resourceFork,
                encoding: encoding
            )
            do {
                try await send(bytes: sizePrefix, on: outChannel)
                try await send(bytes: framed, on: outChannel)
            } catch {
                return
            }
        }

        // Zero-length header signals end-of-stream to the decoder.
        var trailer = Data()
        trailer.appendBigEndian(UInt16(0))
        try? await send(bytes: trailer, on: outChannel)
    }

    /// Same wire format as `FolderUploadFraming.encodeItemHeader` —
    /// `UInt16 itemHeaderLength` + `UInt16 isDirectory` (0/1) + the
    /// `RemotePath.encoded` blob of components.
    private static func encodeItemHeader(
        relativePath: [String],
        isDirectory: Bool,
        encoding: String.Encoding
    ) -> Data {
        FolderUploadFraming.encodeItemHeader(
            relativePath: relativePath,
            isDirectory: isDirectory,
            encoding: encoding
        )
    }

    private static func send(bytes: Data, on channel: any Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    private static func readUInt16(_ data: Data) -> UInt16 {
        let base = data.startIndex
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }
}
