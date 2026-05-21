import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("FileVault")
struct FileVaultTests {
    private func makeVaultWithSeededFiles() async throws -> (FileVault, URL) {
        let vault = try FileVault(rootPath: nil)
        let root = await vault.root
        let fileManager = FileManager.default
        // Seed: <root>/readme.txt and <root>/Folder/inside.txt
        try Data("hello world".utf8).write(to: root.appendingPathComponent("readme.txt"))
        let subfolder = root.appendingPathComponent("Folder", isDirectory: true)
        try fileManager.createDirectory(at: subfolder, withIntermediateDirectories: true)
        try Data("nested content".utf8).write(to: subfolder.appendingPathComponent("inside.txt"))
        return (vault, root)
    }

    @Test("list at root surfaces both the file and the folder")
    func listRoot() async throws {
        let (vault, _) = try await makeVaultWithSeededFiles()
        let entries = await vault.list(at: [])
        let names = Set(entries?.map(\.name) ?? [])
        #expect(names == Set(["readme.txt", "Folder"]))
        let folder = entries?.first(where: { $0.name == "Folder" })
        #expect(folder?.type == .folder)
        #expect(folder?.itemCount == 1)
    }

    @Test("list at a sub-path surfaces inner files")
    func listSubfolder() async throws {
        let (vault, _) = try await makeVaultWithSeededFiles()
        let entries = await vault.list(at: ["Folder"])
        #expect(entries?.first?.name == "inside.txt")
        #expect(entries?.first?.type == .file)
    }

    @Test("info returns size + modification date for a known file")
    func infoForFile() async throws {
        let (vault, _) = try await makeVaultWithSeededFiles()
        let info = await vault.info(at: [], name: "readme.txt")
        #expect(info?.entry.size == UInt32("hello world".utf8.count))
        #expect(info?.modified != .distantPast)
    }

    @Test("list rejects path components containing slash or .. and returns nil")
    func rejectsTraversal() async throws {
        let (vault, _) = try await makeVaultWithSeededFiles()
        #expect(await vault.list(at: [".."]) == nil)
        #expect(await vault.list(at: ["Folder/.."]) == nil)
        #expect(await vault.info(at: [], name: "../escape") == nil)
    }

    @Test("list on a missing path returns nil")
    func missingPath() async throws {
        let (vault, _) = try await makeVaultWithSeededFiles()
        #expect(await vault.list(at: ["nope"]) == nil)
    }
}
