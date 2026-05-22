import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Folder transfers (HTXF)", .serialized)
struct FolderTransferTests {

    private func withSeededFilesServer<Result>(
        body: (UInt16, URL) async throws -> Result
    ) async throws -> Result {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "HeidrunServer-FolderXfer-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun folder-transfer test",
            filesRootPath: rootURL.path
        )
        return try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            try await body(port, rootURL)
        }
    }

    @Test("download a folder containing a nested file yields the file + its bytes")
    func downloadRoundTrip() async throws {
        try await withSeededFilesServer { port, rootURL in
            // Seed: Project/notes.txt + Project/sub/inner.txt
            let projectURL = rootURL.appendingPathComponent("Project", isDirectory: true)
            let subURL = projectURL.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: subURL, withIntermediateDirectories: true)
            let notesPayload = Data("top-level notes".utf8)
            let innerPayload = Data("inside the sub-folder".utf8)
            try notesPayload.write(to: projectURL.appendingPathComponent("notes.txt"))
            try innerPayload.write(to: subURL.appendingPathComponent("inner.txt"))

            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let networkClient = try #require(client as? HotlineNetworkClient)
            let handle = try await networkClient.startFolderDownload(
                at: RemotePath(components: []),
                name: "Project"
            )

            var seen: [String: Data] = [:]
            var directoriesSeen: Set<String> = []
            for try await item in networkClient.folderDownloadStream(for: handle) {
                let joined = item.relativePath.joined(separator: "/")
                if item.isDirectory {
                    directoriesSeen.insert(joined)
                } else {
                    seen[joined] = item.data
                }
            }

            #expect(directoriesSeen.contains("sub"))
            #expect(seen["notes.txt"] == notesPayload)
            #expect(seen["sub/inner.txt"] == innerPayload)
        }
    }

    @Test("upload a folder writes every item into the vault under the new root")
    func uploadRoundTrip() async throws {
        try await withSeededFilesServer { port, rootURL in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let networkClient = try #require(client as? HotlineNetworkClient)

            let alpha = Data("alpha contents".utf8)
            let beta  = Data("beta contents inside sub".utf8)
            let items: [FolderUploadItem] = [
                FolderUploadItem(relativePath: ["alpha.txt"], isDirectory: false, data: alpha),
                FolderUploadItem(relativePath: ["sub"], isDirectory: true),
                FolderUploadItem(relativePath: ["sub", "beta.txt"], isDirectory: false, data: beta)
            ]
            let totalSize = items.reduce(UInt32(0)) { running, item in
                running &+ UInt32(item.data.count)
            }

            let handle = try await networkClient.startFolderUpload(
                at: RemotePath(components: []),
                name: "Uploaded",
                size: totalSize,
                itemCount: UInt16(items.count),
                resume: false
            )
            try await networkClient.sendFolderUpload(items, for: handle)
            try await Task.sleep(for: .milliseconds(300))

            let uploadedRoot = rootURL.appendingPathComponent("Uploaded", isDirectory: true)
            let alphaURL = uploadedRoot.appendingPathComponent("alpha.txt")
            let betaURL = uploadedRoot
                .appendingPathComponent("sub", isDirectory: true)
                .appendingPathComponent("beta.txt")

            #expect(FileManager.default.fileExists(atPath: alphaURL.path))
            #expect(FileManager.default.fileExists(atPath: betaURL.path))
            #expect((try? Data(contentsOf: alphaURL)) == alpha)
            #expect((try? Data(contentsOf: betaURL)) == beta)
        }
    }
}
