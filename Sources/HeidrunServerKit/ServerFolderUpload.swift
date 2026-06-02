import Foundation
import HeidrunCore
import NIOCore

/// Server-side driver for one folder-upload HTXF stream.
///
/// Mirrors `ServerFolderDownload` but inverted: the client supplies
/// the items. For each of `itemCount` cycles:
///
///   1. Read `UInt16 itemHeaderLength + body`. Body is the
///      `FolderUploadFraming` blob: `UInt16 isDirectory + path`.
///   2. Write back the action — always `1` (upload) for files; for
///      directories we acknowledge with `1` and skip the payload (the
///      client treats directories as zero-length payloads anyway —
///      pure metadata that telling us to mkdir).
///   3. For files, read `UInt32 itemFileSize` + that many bytes, then
///      hand the framed envelope to `UploadFraming.decode` and write
///      the file into the vault.
///   4. Send `UInt16 3` (`readyForNextItem`) before reading the next
///      header, except after the last item.
///
/// The folder root is created lazily inside the vault — every item's
/// relative path is rooted at `(path, name)`.
enum ServerFolderUpload {

    static func drain(
        stream: inout ByteStream<AsyncStream<Data>>,
        outChannel: any Channel,
        files: FileVault,
        path: [String],
        name: String,
        itemCount: UInt16,
        encoding: String.Encoding
    ) async {
        // Ensure the folder root exists. Failures here are silent —
        // the caller may have already created it via createFolder.
        _ = await files.createFolder(at: path, name: name)
        let rootPath = path + [name]

        for index in 0..<itemCount {
            if index > 0 {
                var sync = Data()
                sync.appendBigEndian(FolderUploadFraming.readyForNextItem)
                do { try await send(bytes: sync, on: outChannel) } catch { return }
            }

            // Read item header length + body.
            guard let lenBytes = try? await stream.receiveExactly(2) else { return }
            let headerLen = readUInt16(lenBytes)
            guard headerLen > 0 else { return }
            guard let body = try? await stream.receiveExactly(Int(headerLen)) else { return }

            let parsed = parseItemHeader(body, encoding: encoding)

            // Ack with 1 (upload). For directories the client doesn't
            // send a payload — it just expects us to acknowledge so
            // it moves to the next item.
            var ack = Data()
            ack.appendBigEndian(FolderUploadFraming.ItemAction.upload.rawValue)
            do { try await send(bytes: ack, on: outChannel) } catch { return }

            if parsed.isDirectory {
                // Materialize the sub-directory inside the vault.
                let dirParent = rootPath + parsed.components.dropLast()
                let dirName = parsed.components.last ?? ""
                if !dirName.isEmpty {
                    _ = await files.createFolder(at: Array(dirParent), name: dirName)
                }
                continue
            }

            // File: UInt32 size + framed envelope.
            guard let sizeBytes = try? await stream.receiveExactly(4) else { return }
            let size = readUInt32(sizeBytes)
            guard let payload = try? await stream.receiveExactly(Int(size)) else { return }
            guard let envelope = try? UploadFraming.decode(payload, encoding: encoding) else {
                continue
            }
            let fileParent = rootPath + parsed.components.dropLast()
            let storedName = parsed.components.last ?? envelope.fileName
            guard !storedName.isEmpty else { continue }
            let wrote = await files.putFile(
                at: Array(fileParent),
                name: storedName,
                data: envelope.data,
                resourceFork: envelope.resourceFork,
                type: envelope.type,
                creator: envelope.creator,
                resume: false
            )
            if wrote {
                serverLogger.info("folder upload: file written", metadata: [
                    "path": "\((fileParent + [storedName]).joined(separator: "/"))",
                    "bytes": "\(envelope.data.count)"
                ])
            } else {
                // Per-file collision: the target already exists inside
                // the folder being uploaded. We can't issue a control-
                // channel error here (we're mid-HTXF), but we log so
                // the operator can see the gap, and keep draining the
                // remaining items rather than dropping the whole
                // bundle.
                serverLogger.warning("folder upload: file skipped (collision or write error)", metadata: [
                    "path": "\((fileParent + [storedName]).joined(separator: "/"))",
                    "bytes": "\(envelope.data.count)"
                ])
            }
        }
    }

    private static func parseItemHeader(_ data: Data, encoding: String.Encoding) -> ParsedHeader {
        var cursor = data.startIndex
        let isDir = readUInt16(Data(data[cursor..<(cursor + 2)]))
        cursor += 2
        let count = Int(readUInt16(Data(data[cursor..<(cursor + 2)])))
        cursor += 2
        var components: [String] = []
        components.reserveCapacity(count)
        for _ in 0..<count {
            guard data.endIndex - cursor >= 3 else { break }
            cursor += 2                                     // 2-byte pad
            let length = Int(data[cursor])
            cursor += 1
            guard data.endIndex - cursor >= length else { break }
            let nameBytes = data[cursor..<(cursor + length)]
            cursor += length
            components.append(String(data: Data(nameBytes), encoding: encoding) ?? "")
        }
        return ParsedHeader(isDirectory: isDir != 0, components: components)
    }

    struct ParsedHeader {
        let isDirectory: Bool
        let components: [String]
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

    private static func readUInt32(_ data: Data) -> UInt32 {
        let base = data.startIndex
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }
}
