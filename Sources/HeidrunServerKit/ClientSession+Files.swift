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
