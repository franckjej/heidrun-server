import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle `getFileList` (200): walk to the requested path and reply
    /// with one `fileListEntry` per child. Errors with errorID=1 when
    /// the path doesn't exist or isn't a directory.
    func handleListFiles(header: PacketHeader, fields: [PacketField]) async {
        guard hasPrivilege(.downloadFiles) || hasPrivilege(.downloadFolders) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 200, privilege: "downloadFiles")
            return
        }
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
            largeFile: largeFiles,
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
    /// download — only the data-fork offset is honoured.
    ///
    /// When the session negotiated `resourceForkSupport` AND the client
    /// requested a fresh download (offset == 0), the side channel
    /// instead ships the FILP/INFO/DATA/MACR envelope so the resource
    /// fork (read from the `._<name>.rsrc` sidecar) travels with the
    /// data fork.
    func handleDownloadFile(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 202,
                message: "missing fileName field",
                encoding: stringEncoding
            ))
            return
        }
        guard hasPrivilege(.downloadFiles) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 202, privilege: "downloadFiles")
            return
        }
        guard let bytes = await files.bytes(at: path, name: name) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 202,
                message: "file not found: \(displayPath(path, name: name))",
                encoding: stringEncoding
            ))
            return
        }
        var legacyResumeOffset: UInt32 = 0
        if let resumeField = fields.first(.fileResumeInfo),
           let info = ResumeInfoCodec.decode(resumeField.data) {
            legacyResumeOffset = info.dataForkOffset
        }
        // Large-file clients carry the resume offset as a 64-bit field;
        // fall back to the 32-bit legacy ResumeInfo offset otherwise.
        let offset: UInt64 = fields.uint64(.offset64) ?? UInt64(legacyResumeOffset)
        let remaining: UInt64 = offset >= UInt64(bytes.count) ? 0 : UInt64(bytes.count) - offset

        // Negotiated single-file framing only kicks in for fresh
        // downloads — resume + framing isn't a supported combo (the
        // FILP envelope's INFO/MACR headers wouldn't make sense over a
        // partial data fork; downloadEnvelope on the client side
        // requires .framed handles).
        if self.supportsResourceForks, offset == 0 {
            let resourceFork = await files.resourceFork(at: path, name: name)
            let metadata = await files.info(at: path, name: name)
            let envelope = UploadFraming.encode(
                fileName: name,
                type: metadata?.entry.type ?? .file,
                creator: metadata?.entry.creator ?? .unknown,
                creationDate: metadata?.created ?? Date(),
                modificationDate: metadata?.modified ?? Date(),
                data: bytes,
                resourceFork: resourceFork,
                encoding: stringEncoding
            )
            let transferID = await transfers.registerFramedDownload(envelope: envelope)
            await audit(.download, target: name, bytes: Int64(envelope.count), result: "granted")
            let envelopeSize = UInt64(envelope.count)
            try? await writer(PacketEncoder.downloadFileReply(
                taskNumber: header.taskNumber,
                transferID: transferID,
                transferSize: UInt32(clamping: envelopeSize),
                size64: largeFiles && envelopeSize > 0xFFFF_FFFF ? envelopeSize : nil
            ))
            return
        }

        let transferID = await transfers.registerDownload(bytes: bytes, offset: offset)
        await audit(.download, target: name, bytes: Int64(bytes.count), result: "granted")
        try? await writer(PacketEncoder.downloadFileReply(
            taskNumber: header.taskNumber,
            transferID: transferID,
            transferSize: UInt32(clamping: remaining),
            size64: largeFiles && remaining > 0xFFFF_FFFF ? remaining : nil
        ))
    }

    /// Handle `getFileInfo` (206): reply with metadata for the addressed
    /// file (name, type, creator, size, timestamps, comment).
    func handleFileInfo(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 206,
                message: "missing fileName field",
                encoding: stringEncoding
            ))
            return
        }
        guard hasPrivilege(.downloadFiles) || hasPrivilege(.downloadFolders) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 206, privilege: "downloadFiles")
            return
        }
        guard let info = await files.info(at: path, name: name) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 206,
                message: "file not found: \(displayPath(path, name: name))",
                encoding: stringEncoding
            ))
            return
        }
        try? await writer(PacketEncoder.fileInfoReply(
            taskNumber: header.taskNumber,
            info: info,
            largeFile: largeFiles,
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
        guard hasPrivilege(.downloadFolders) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 210, privilege: "downloadFolders")
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
        await audit(.download, target: name, result: "granted", detail: "folder")
        try? await writer(PacketEncoder.downloadFileReply(
            taskNumber: header.taskNumber,
            transferID: transferID,
            transferSize: totalSize
        ))
    }

    /// Handle `uploadFolder` (213): register a pending
    /// `.folderUpload`, reply with the transferID so the client can
    /// open its HTXF connection and start streaming items. Per-item
    /// existence checks happen in `ServerFolderUpload.drain` — at the
    /// top level we allow the folder name itself to merge with an
    /// existing directory (the FileVault `createFolder` call is a
    /// no-op if the directory exists), but individual files inside
    /// will not silently overwrite.
    func handleUploadFolder(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 213
            ))
            return
        }
        guard hasPrivilege(.uploadFolders) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 213, privilege: "uploadFolders")
            return
        }
        let itemCount = fields.uint16(.folderItemCount) ?? 0
        let transferID = await transfers.registerFolderUpload(
            path: path,
            name: name,
            itemCount: itemCount
        )
        await audit(.upload, target: name, result: "granted", detail: "folder")
        serverLogger.info("folder upload accepted", metadata: [
            "nickname": "\(nickname)",
            "socketID": "\(socketID)",
            "path": "\(displayPath(path, name: name))",
            "itemCount": "\(itemCount)",
            "transferID": "\(transferID)"
        ])
        try? await writer(PacketEncoder.uploadFileReply(
            taskNumber: header.taskNumber,
            transferID: transferID
        ))
    }

    /// Handle `uploadFile` (203). Mirrors download: register a pending
    /// transfer of kind `.upload`, reply with the assigned transferID.
    /// The client then opens an HTXF connection on port + 1 carrying
    /// that ID and the FILP envelope.
    ///
    /// Refuses silent overwrites: when a file already exists at
    /// `(path, name)` and the client did not set the resume parameter,
    /// the upload is rejected with a human-readable error message
    /// instead of allocating a transfer slot. The client can re-issue
    /// with resume=1 (append) or delete the existing file first via
    /// TX 204.
    func handleUploadFile(header: PacketHeader, fields: [PacketField]) async {
        let path = filePath(from: fields)
        guard let name = fields.string(.fileName, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 203
            ))
            return
        }
        guard hasPrivilege(.uploadFiles) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 203, privilege: "uploadFiles")
            return
        }
        // Large-file clients declare the upload size as a 64-bit field;
        // fall back to the legacy 32-bit transferSize otherwise.
        let declaredSize = fields.uint64(.xferSize64) ?? UInt64(fields.uint32(.transferSize) ?? 0)
        let resume = (fields.uint16(.parameter) ?? 0) == 1

        if !resume, await files.info(at: path, name: name) != nil {
            serverLogger.info("upload rejected: target exists", metadata: [
                "nickname": "\(nickname)",
                "socketID": "\(socketID)",
                "path": "\(displayPath(path, name: name))",
                "declaredSize": "\(declaredSize)"
            ])
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 203,
                message: "file '\(name)' already exists at this location",
                kind: .fileAlreadyExists,
                encoding: stringEncoding
            ))
            return
        }

        let transferID = await transfers.registerUpload(
            path: path,
            name: name,
            declaredSize: declaredSize,
            resume: resume
        )
        await audit(.upload, target: name, bytes: Int64(declaredSize), result: "granted")
        serverLogger.info("upload accepted", metadata: [
            "nickname": "\(nickname)",
            "socketID": "\(socketID)",
            "path": "\(displayPath(path, name: name))",
            "declaredSize": "\(declaredSize)",
            "resume": "\(resume)",
            "transferID": "\(transferID)"
        ])
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
        let isFolder = await files.isFolder(at: path, name: name) == true
        guard hasPrivilege(isFolder ? .deleteFolders : .deleteFiles) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 204,
                                privilege: isFolder ? "deleteFolders" : "deleteFiles")
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
        guard hasPrivilege(.createFolders) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 205, privilege: "createFolders")
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
        let isFolder = await files.isFolder(at: path, name: name) == true
        var currentName = name
        if let newName = fields.string(.fileRename, encoding: stringEncoding), !newName.isEmpty {
            guard hasPrivilege(isFolder ? .renameFolders : .renameFiles) else {
                await denyPrivilege(taskNumber: header.taskNumber, transactionID: 207,
                                    privilege: isFolder ? "renameFolders" : "renameFiles")
                return
            }
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
            guard hasPrivilege(isFolder ? .commentFolders : .commentFiles) else {
                await denyPrivilege(taskNumber: header.taskNumber, transactionID: 207,
                                    privilege: isFolder ? "commentFolders" : "commentFiles")
                return
            }
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
        let isFolder = await files.isFolder(at: sourcePath, name: name) == true
        guard hasPrivilege(isFolder ? .moveFolders : .moveFiles) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 208,
                                privilege: isFolder ? "moveFolders" : "moveFiles")
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
        guard hasPrivilege(.makeAliases) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 209, privilege: "makeAliases")
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

    /// Format a path + file name for human-readable error messages
    /// ("Software/Mac/foo.txt" rather than `["Software","Mac"]`,
    /// "foo.txt"). Used in `errorReply` `message:` fields so the
    /// client can surface a useful line instead of bare "error 1".
    fileprivate func displayPath(_ path: [String], name: String) -> String {
        let joined = path.joined(separator: "/")
        return joined.isEmpty ? name : "\(joined)/\(name)"
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
