import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("File browsing", .serialized)
struct FileBrowsingTests {
    /// Spin up a server with a seeded files root and an in-memory account store.
    private func withSeededFilesServer<Result>(
        body: (HeidrunServer, UInt16, URL) async throws -> Result
    ) async throws -> Result {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "HeidrunServer-Test-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // Seed: <root>/readme.txt and <root>/Folder/inside.txt
        try Data("hello world".utf8).write(to: rootURL.appendingPathComponent("readme.txt"))
        let subfolder = rootURL.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try Data("nested content".utf8).write(to: subfolder.appendingPathComponent("inside.txt"))

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

    @Test("listFiles at root returns the seeded files and folder")
    func listRoot() async throws {
        try await withSeededFilesServer { _, port, _ in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let entries = try await client.listFiles(at: RemotePath(components: []))
            let names = Set(entries.map(\.name))
            #expect(names == Set(["readme.txt", "Folder"]))
            let folder = entries.first(where: { $0.name == "Folder" })
            #expect(folder?.type == .folder)
        }
    }

    @Test("listFiles at a subfolder returns the nested file")
    func listSubfolder() async throws {
        try await withSeededFilesServer { _, port, _ in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let entries = try await client.listFiles(at: RemotePath(components: ["Folder"]))
            #expect(entries.first?.name == "inside.txt")
        }
    }

    @Test("fetchFileInfo returns size + modification date for a known file")
    func fileInfo() async throws {
        try await withSeededFilesServer { _, port, _ in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let info = try await client.fetchFileInfo(
                at: RemotePath(components: []),
                name: "readme.txt"
            )
            #expect(info.file.size == UInt32("hello world".utf8.count))
            #expect(info.modificationDate != nil)
        }
    }

    @Test("fetchFileInfo on a missing file throws")
    func fileInfoMissing() async throws {
        try await withSeededFilesServer { _, port, _ in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            do {
                _ = try await client.fetchFileInfo(
                    at: RemotePath(components: []),
                    name: "nope.txt"
                )
                #expect(Bool(false), "expected error reply for missing file")
            } catch {
                // expected
            }
        }
    }
}
