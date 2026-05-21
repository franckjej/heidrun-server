import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle `getFileList` (200): walk to the requested path and reply
    /// with one `fileListEntry` per child. Errors with errorID=1 when
    /// the path doesn't exist or isn't a directory.
    func handleListFiles(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let entries = await files.list(at: path) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 200
            ))
            return
        }
        try? await writer(PacketEncoder.fileListReply(
            taskNumber: header.taskNumber,
            entries: entries,
            encoding: stringEncoding
        ))
    }

    /// Handle `downloadFile` (202): look up the file's bytes in
    /// `FileVault`, register a pending transfer keyed by a fresh
    /// transferID, and reply with `(.transferID, .transferSize)`. The
    /// client then opens a new TCP connection to the HTXF port + 1 and
    /// sends a 16-byte preamble carrying that transferID; the server's
    /// transfer-channel handler matches the ID and streams the bytes.
    ///
    /// `.fileResumeInfo` (203) lets the client resume an aborted
    /// download — only the data-fork offset is honoured (we don't
    /// preserve resource forks).
    func handleDownloadFile(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 202
            ))
            return
        }
        guard let bytes = await files.bytes(at: path, name: name) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 202
            ))
            return
        }
        var offset: UInt32 = 0
        if let resumeField = fields.first(.fileResumeInfo),
           let info = ResumeInfoCodec.decode(resumeField.data) {
            offset = info.dataForkOffset
        }
        let remaining = UInt32(clamping: max(0, bytes.count - Int(offset)))
        let transferID = await transfers.registerDownload(bytes: bytes, offset: offset)
        try? await writer(PacketEncoder.downloadFileReply(
            taskNumber: header.taskNumber,
            transferID: transferID,
            transferSize: remaining
        ))
    }

    /// Handle `getFileInfo` (206): reply with metadata for the addressed
    /// file (name, type, creator, size, timestamps, comment).
    func handleFileInfo(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 206
            ))
            return
        }
        guard let info = await files.info(at: path, name: name) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 206
            ))
            return
        }
        try? await writer(PacketEncoder.fileInfoReply(
            taskNumber: header.taskNumber,
            info: info,
            encoding: stringEncoding
        ))
    }

    /// Decode the `.filePath` (202) field into `[String]`. Defaults to
    /// `[]` (root) when the field is missing or malformed.
    fileprivate func filePath(from fields: [PacketField]) -> [String] {
        guard let field = fields.first(.filePath),
              let path = RemotePath(decoding: field.data, encoding: stringEncoding) else {
            return []
        }
        return path.components
    }
}
