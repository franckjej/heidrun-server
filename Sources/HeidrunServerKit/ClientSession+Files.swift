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

    /// Handle `downloadFolder` (210): walk the folder, register a
    /// pending `.folderDownload` transfer keyed by a fresh transferID,
    /// and reply with `(.transferID, .transferSize)` so the client can
    /// open its HTXF connection and consume the framed item stream.
    func handleDownloadFolder(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 210
            ))
            return
        }
        guard let items = await files.enumerate(at: path, name: name) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 210
            ))
            return
        }
        let totalSize = items.reduce(UInt32(0)) { running, item in
            guard !item.isDirectory else { return running }
            let nameBytes = (item.relativePath.last ?? "")
                .data(using: stringEncoding, allowLossyConversion: true) ?? Data()
            let per = UploadFraming.totalSize(
                nameLength: nameBytes.count,
                dataLength: UInt32(item.data.count)
            )
            return running &+ per &+ 4    // 4 bytes for the UInt32 itemFileSize prefix
        }
        let transferID = await transfers.registerFolderDownload(items: items)
        try? await writer(PacketEncoder.downloadFileReply(
            taskNumber: header.taskNumber,
            transferID: transferID,
            transferSize: totalSize
        ))
    }

    /// Handle `uploadFolder` (213): register a pending
    /// `.folderUpload`, reply with the transferID so the client can
    /// open its HTXF connection and start streaming items.
    func handleUploadFolder(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 213
            ))
            return
        }
        let itemCount = fields.uint16(.folderItemCount) ?? 0
        let transferID = await transfers.registerFolderUpload(
            path: path,
            name: name,
            itemCount: itemCount
        )
        try? await writer(PacketEncoder.uploadFileReply(
            taskNumber: header.taskNumber,
            transferID: transferID
        ))
    }

    /// Handle `uploadFile` (203). Mirrors download: register a pending
    /// transfer of kind `.upload`, reply with the assigned transferID.
    /// The client then opens an HTXF connection on port + 1 carrying
    /// that ID and the FILP envelope.
    func handleUploadFile(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 203
            ))
            return
        }
        let declaredSize = fields.uint32(.transferSize) ?? 0
        let resume = (fields.uint16(.parameter) ?? 0) == 1
        let transferID = await transfers.registerUpload(
            path: path,
            name: name,
            declaredSize: declaredSize,
            resume: resume
        )
        try? await writer(PacketEncoder.uploadFileReply(
            taskNumber: header.taskNumber,
            transferID: transferID
        ))
    }

    /// Handle `deleteEntry` (204).
    func handleDeleteEntry(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 204
            ))
            return
        }
        let ok = await files.delete(at: path, name: name)
        if ok {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 204
            ))
        } else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 204
            ))
        }
    }

    /// Handle `createFolder` (205).
    func handleCreateFolder(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 205
            ))
            return
        }
        let ok = await files.createFolder(at: path, name: name)
        if ok {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 205
            ))
        } else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 205
            ))
        }
    }

    /// Handle `setFileInfo` (207). Accepts a rename via `.fileRename`
    /// (211) and/or a comment via `.fileComment` (210). When both are
    /// present, the rename runs first and the comment is applied to
    /// the new path. Empty / missing fields are no-ops.
    func handleSetFileInfo(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 207
            ))
            return
        }
        var currentName = name
        if let newName = fields.string(.fileRename, encoding: stringEncoding), !newName.isEmpty {
            let renamed = await files.rename(at: path, from: currentName, to: newName)
            guard renamed else {
                try? await writer(PacketEncoder.errorReply(
                    taskNumber: header.taskNumber,
                    transactionID: 207
                ))
                return
            }
            currentName = newName
        }
        if let comment = fields.string(.fileComment, encoding: stringEncoding) {
            let saved = await files.setComment(at: path, name: currentName, comment: comment)
            guard saved else {
                try? await writer(PacketEncoder.errorReply(
                    taskNumber: header.taskNumber,
                    transactionID: 207
                ))
                return
            }
        }
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber,
            transactionID: 207
        ))
    }

    /// Handle `moveEntry` (208). The new parent path arrives in the
    /// `.destinationPath` field (key 212).
    func handleMoveEntry(header: PacketHeader, fields: [PacketField]) async {
        let sourcePath = filePath(from: fields)
        let destinationPath = destinationFilePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 208
            ))
            return
        }
        let ok = await files.move(from: sourcePath, name: name, to: destinationPath)
        if ok {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 208
            ))
        } else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 208
            ))
        }
    }

    /// Handle `makeFileAlias` (209) — places a symlink at the
    /// destination pointing back at the source. Filesystems without
    /// symlink support will fail here; macOS + Linux are fine.
    func handleMakeAlias(header: PacketHeader, fields: [PacketField]) async {
        let sourcePath = filePath(from: fields)
        let destinationPath = destinationFilePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 209
            ))
            return
        }
        let ok = await files.makeAlias(from: sourcePath, name: name, to: destinationPath)
        if ok {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 209
            ))
        } else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 209
            ))
        }
    }

    fileprivate func destinationFilePath(from fields: [PacketField]) -> [String] {
        guard let field = fields.first(.destinationPath),
              let path = RemotePath(decoding: field.data, encoding: stringEncoding) else {
            return []
        }
        return path.components
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
