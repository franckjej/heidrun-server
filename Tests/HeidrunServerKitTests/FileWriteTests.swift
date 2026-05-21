import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("File writes", .serialized)
struct FileWriteTests {
    private func withSeededFilesServer<Result>(
        body: (HeidrunServer, UInt16, URL) async throws -> Result
    ) async throws -> Result {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "HeidrunServer-Writes-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            filesRootPath: rootURL.path
        )
        return try await ServerTestHelpers.withRunningServer(configuration: configuration) { server, port in
            try await body(server, port, rootURL)
        }
    }

    @Test("createFolder + listFiles round-trips a new folder")
    func createFolder() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            try await client.createFolder(at: RemotePath(components: []), name: "Photos")
            let entries = try await client.listFiles(at: RemotePath(components: []))
            #expect(entries.contains(where: { $0.name == "Photos" && $0.type == .folder }))
            // Verify on disk.
            let onDisk = rootURL.appendingPathComponent("Photos", isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: onDisk.path))
        }
    }

    @Test("deleteEntry removes an existing file")
    func deleteFile() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            try Data("bye".utf8).write(to: rootURL.appendingPathComponent("disposable.txt"))
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            try await client.deleteEntry(at: RemotePath(components: []), name: "disposable.txt")
            let entries = try await client.listFiles(at: RemotePath(components: []))
            #expect(entries.isEmpty)
        }
    }

    @Test("updateFileMetadata rename moves the file on disk")
    func renameFile() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            try Data("hello".utf8).write(to: rootURL.appendingPathComponent("old.txt"))
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            try await client.updateFileMetadata(
                at: RemotePath(components: []),
                name: "old.txt",
                change: .rename(newName: "new.txt")
            )
            // updateFileMetadata is `sendNoReply` — the client doesn't
            // wait for the server to commit. Use a follow-up info call
            // as a barrier (the reply only arrives after the rename has
            // landed) before checking disk state.
            _ = try await client.listFiles(at: RemotePath(components: []))
            #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("old.txt").path))
            #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("new.txt").path))
        }
    }

    @Test("updateFileMetadata comment makes fetchFileInfo return that comment")
    func setComment() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            try Data("noted".utf8).write(to: rootURL.appendingPathComponent("notes.txt"))
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            try await client.updateFileMetadata(
                at: RemotePath(components: []),
                name: "notes.txt",
                change: .comment(newComment: "important file")
            )
            // fetchFileInfo is reply-bearing and naturally acts as a
            // barrier after the no-reply updateFileMetadata.
            let info = try await client.fetchFileInfo(
                at: RemotePath(components: []),
                name: "notes.txt"
            )
            #expect(info.comment == "important file")
        }
    }

    @Test("moveEntry moves a file into a subfolder")
    func moveFile() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            let fileManager = FileManager.default
            try Data("payload".utf8).write(to: rootURL.appendingPathComponent("movable.txt"))
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent("Inbox", isDirectory: true),
                withIntermediateDirectories: true
            )
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            try await client.moveEntry(
                from: RemotePath(components: []),
                name: "movable.txt",
                to: RemotePath(components: ["Inbox"])
            )
            // moveEntry is `sendNoReply` — barrier on a follow-up
            // reply-bearing transaction.
            _ = try await client.listFiles(at: RemotePath(components: []))
            #expect(!fileManager.fileExists(atPath: rootURL.appendingPathComponent("movable.txt").path))
            #expect(fileManager.fileExists(atPath: rootURL.appendingPathComponent("Inbox/movable.txt").path))
        }
    }

    @Test("startUpload + sendUpload commits the data fork to disk and download round-trips")
    func uploadFile() async throws {
        try await withSeededFilesServer { _, port, rootURL in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let payload = Data("uploaded payload bytes".utf8)

            let handle = try await client.startUpload(
                at: RemotePath(components: []),
                name: "uploaded.txt",
                size: UInt32(payload.count),
                resume: false
            )
            try await client.sendUpload(payload, for: handle, fileName: "uploaded.txt")

            // Give the side-channel a moment to commit. The HTXF
            // upload handler writes asynchronously after sendUpload
            // returns (sendUpload awaits the write completing on the
            // client side, but the server-side commit happens after
            // the channel close).
            try await Task.sleep(for: .milliseconds(200))

            // Hit the disk directly to confirm the file landed.
            let onDisk = rootURL.appendingPathComponent("uploaded.txt")
            let storedBytes = try Data(contentsOf: onDisk)
            #expect(storedBytes == payload)

            // And confirm the download round-trips the bytes too.
            let downloadHandle = try await client.startDownload(
                at: RemotePath(components: []),
                name: "uploaded.txt",
                dataForkOffset: 0,
                resourceForkOffset: 0
            )
            var received = Data()
            for try await chunk in client.downloadStream(for: downloadHandle) {
                received.append(chunk)
            }
            #expect(received == payload)
        }
    }
}
