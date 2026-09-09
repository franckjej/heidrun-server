import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Drop boxes and upload folders", .serialized)
struct DropBoxTests {
    private func withDropBoxServer<Result>(
        body: (UInt16, URL) async throws -> Result
    ) async throws -> Result {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "HeidrunServer-DropBox-\(UUID().uuidString)", isDirectory: true)
        let dropBox = rootURL.appendingPathComponent("Drop Box", isDirectory: true)
        let inner = dropBox.appendingPathComponent("Inner", isDirectory: true)
        try fileManager.createDirectory(at: inner, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: rootURL.appendingPathComponent("Uploads/2026", isDirectory: true),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: rootURL.appendingPathComponent("Public", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: dropBox.appendingPathComponent("secret.txt"))
        try Data("deep".utf8).write(to: inner.appendingPathComponent("deep.txt"))
        defer { try? fileManager.removeItem(at: rootURL) }

        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun drop box test",
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"),
            filesRootPath: rootURL.path
        )
        return try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            try await body(port, rootURL)
        }
    }

    private func guest(port: UInt16) async throws -> any HotlineClient {
        try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Guest")
    }

    private func admin(port: UInt16) async throws -> any HotlineClient {
        try await ServerTestHelpers.connectAndLogin(
            port: port, nickname: "Admin", loginName: "admin", password: "admin")
    }

    /// Runs `operation` and returns the server's error message, or nil
    /// when it succeeded.
    private func refusalMessage(_ operation: () async throws -> Void) async -> String? {
        do {
            try await operation()
            return nil
        } catch let HotlineError.serverError(_, message) {
            return message ?? ""
        } catch {
            return "\(error)"
        }
    }

    // MARK: Reads

    @Test("the drop box folder itself is listed in its parent")
    func dropBoxVisibleInParent() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await guest(port: port)
            let entries = try await client.listFiles(at: [])
            let entry = try #require(entries.first(where: { $0.name == "Drop Box" }))
            #expect(entry.type == .folder)
        }
    }

    @Test("listing a drop box without viewDropBoxes is refused with the drop box message")
    func listRefused() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await guest(port: port)
            let message = await refusalMessage { _ = try await client.listFiles(at: ["Drop Box"]) }
            #expect(message?.contains("drop box") == true)
        }
    }

    @Test("listing a folder nested inside a drop box is refused too")
    func nestedListRefused() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await guest(port: port)
            let message = await refusalMessage { _ = try await client.listFiles(at: ["Drop Box", "Inner"]) }
            #expect(message?.contains("drop box") == true)
        }
    }

    @Test("file info on the drop box folder itself succeeds; on a file inside it is refused")
    func fileInfoGate() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await guest(port: port)
            let folderInfo = try await client.fetchFileInfo(at: [], name: "Drop Box")
            #expect(folderInfo.file.isFolder)
            let message = await refusalMessage {
                _ = try await client.fetchFileInfo(at: ["Drop Box"], name: "secret.txt")
            }
            #expect(message?.contains("drop box") == true)
        }
    }

    @Test("downloading a file inside a drop box is refused")
    func downloadRefused() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await guest(port: port)
            let message = await refusalMessage {
                _ = try await client.startDownload(
                    at: ["Drop Box"], name: "secret.txt", dataForkOffset: 0, resourceForkOffset: 0)
            }
            #expect(message?.contains("drop box") == true)
        }
    }

    @Test("downloading the drop box folder as a whole is refused")
    func folderDownloadRefused() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await guest(port: port)
            let message = await refusalMessage {
                _ = try await client.startFolderDownload(at: [], name: "Drop Box")
            }
            #expect(message?.contains("drop box") == true)
        }
    }

    @Test("an account with viewDropBoxes lists the drop box normally")
    func privilegedListSucceeds() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await admin(port: port)
            let entries = try await client.listFiles(at: ["Drop Box"])
            #expect(Set(entries.map(\.name)) == ["secret.txt", "Inner"])
        }
    }
}
