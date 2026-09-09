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

    private func editor(port: UInt16) async throws -> any HotlineClient {
        let adminClient = try await admin(port: port)
        try await adminClient.createLogin(
            name: "editor", password: "editor-pw", nickname: "Editor",
            privileges: [.downloadFiles, .deleteFiles, .renameFiles, .moveFiles, .makeAliases])
        return try await ServerTestHelpers.connectAndLogin(
            port: port, nickname: "Editor", loginName: "editor", password: "editor-pw")
    }

    private func uploader(port: UInt16, anywhere: Bool) async throws -> any HotlineClient {
        let adminClient = try await admin(port: port)
        var privileges: UserPrivileges = [.downloadFiles, .uploadFiles, .uploadFolders]
        if anywhere { privileges.insert(.uploadAnywhere) }
        let login = anywhere ? "roamer" : "uploader"
        try await adminClient.createLogin(
            name: login, password: "pw", nickname: login, privileges: privileges)
        return try await ServerTestHelpers.connectAndLogin(
            port: port, nickname: login, loginName: login, password: "pw")
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

    // MARK: Mutations

    @Test("deleting a file inside a drop box without viewDropBoxes is refused and the file survives")
    func deleteRefused() async throws {
        try await withDropBoxServer { port, rootURL in
            let client = try await editor(port: port)
            _ = await refusalMessage { try await client.deleteEntry(at: ["Drop Box"], name: "secret.txt") }
            _ = try await client.listFiles(at: [])   // barrier
            #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Drop Box/secret.txt").path))
        }
    }

    @Test("renaming inside a drop box without viewDropBoxes leaves the file untouched")
    func renameRefused() async throws {
        try await withDropBoxServer { port, rootURL in
            let client = try await editor(port: port)
            try await client.updateFileMetadata(
                at: ["Drop Box"], name: "secret.txt", change: .rename(newName: "leaked.txt"))
            _ = try await client.listFiles(at: [])   // barrier
            #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Drop Box/secret.txt").path))
            #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Drop Box/leaked.txt").path))
        }
    }

    @Test("moving a file out of a drop box without viewDropBoxes is refused; moving one in is allowed")
    func moveGate() async throws {
        try await withDropBoxServer { port, rootURL in
            let client = try await editor(port: port)
            try Data("incoming".utf8).write(to: rootURL.appendingPathComponent("Public/incoming.txt"))
            let message = await refusalMessage {
                try await client.moveEntry(from: ["Drop Box"], name: "secret.txt", to: ["Public"])
            }
            #expect(message?.contains("drop box") == true)
            try await client.moveEntry(from: ["Public"], name: "incoming.txt", to: ["Drop Box"])
            _ = try await client.listFiles(at: [])   // barrier
            #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Drop Box/secret.txt").path))
            #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Public/secret.txt").path))
            #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Drop Box/incoming.txt").path))
        }
    }

    @Test("aliasing a file inside a drop box without viewDropBoxes is refused; aliasing the drop box folder itself works")
    func aliasGate() async throws {
        try await withDropBoxServer { port, rootURL in
            let client = try await editor(port: port)
            try await client.makeAlias(from: ["Drop Box"], name: "secret.txt", to: ["Public"])
            try await client.makeAlias(from: [], name: "Drop Box", to: ["Public"])
            _ = try await client.listFiles(at: [])   // barrier
            #expect(!FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Public/secret.txt").path))
            let publicEntries = try await client.listFiles(at: ["Public"])
            #expect(publicEntries.contains(where: { $0.name == "Drop Box" }))
        }
    }

    @Test("renaming the drop box folder itself follows normal folder privileges")
    func renameDropBoxFolderItself() async throws {
        try await withDropBoxServer { port, rootURL in
            let client = try await admin(port: port)
            try await client.updateFileMetadata(
                at: [], name: "Drop Box", change: .rename(newName: "Team Drop Box"))
            _ = try await client.listFiles(at: [])   // barrier
            #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Team Drop Box").path))
        }
    }

    // MARK: Upload Anywhere

    @Test("without uploadAnywhere, uploading into a plain folder is refused")
    func uploadIntoPlainFolderRefused() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await uploader(port: port, anywhere: false)
            let message = await refusalMessage {
                _ = try await client.startUpload(at: ["Public"], name: "x.txt", size: 1, resume: false)
            }
            #expect(message?.contains("upload folders") == true)
        }
    }

    @Test("without uploadAnywhere, uploads into an upload folder, a nested subfolder of it, and a drop box are accepted")
    func uploadIntoUploadTargetsAccepted() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await uploader(port: port, anywhere: false)
            for path in [RemotePath(components: ["Uploads"]),
                         RemotePath(components: ["Uploads", "2026"]),
                         RemotePath(components: ["Drop Box"])] {
                let handle = try await client.startUpload(at: path, name: "x.txt", size: 1, resume: false)
                #expect(handle.transferID != 0)
            }
        }
    }

    @Test("without uploadAnywhere, a folder upload into a plain folder is refused but into an upload folder is accepted")
    func folderUploadGate() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await uploader(port: port, anywhere: false)
            let message = await refusalMessage {
                _ = try await client.startFolderUpload(
                    at: ["Public"], name: "Stuff", size: 1, itemCount: 1, resume: false)
            }
            #expect(message?.contains("upload folders") == true)
            let handle = try await client.startFolderUpload(
                at: ["Uploads"], name: "Stuff", size: 1, itemCount: 1, resume: false)
            #expect(handle.transferID != 0)
        }
    }

    @Test("with uploadAnywhere, uploading into a plain folder is accepted")
    func uploadAnywhereAccepted() async throws {
        try await withDropBoxServer { port, _ in
            let client = try await uploader(port: port, anywhere: true)
            let handle = try await client.startUpload(at: ["Public"], name: "x.txt", size: 1, resume: false)
            #expect(handle.transferID != 0)
        }
    }
}
