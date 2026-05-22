import Testing
import Foundation
import HeidrunCore
@testable import HeidrunServerKit

@Suite("FileMetadataStore")
struct FileMetadataStoreTests {
    @Test("empty store returns nil for unknown path")
    func emptyLookup() async throws {
        let store = try FileMetadataStore()
        let row = await store.metadata(path: "missing/file.txt")
        #expect(row == nil)
    }

    @Test("setComment + metadata round-trips a comment for one path")
    func commentRoundTrip() async throws {
        let store = try FileMetadataStore()
        _ = await store.setComment(path: "folder/file.txt", comment: "important")

        let row = await store.metadata(path: "folder/file.txt")
        #expect(row?.comment == "important")
        // Type/creator default when no explicit setTypeCreator was called.
        #expect(row?.type == .file)
        #expect(row?.creator == .unknown)
    }

    @Test("setTypeCreator persists 4CC values and keeps any existing comment")
    func typeCreatorPreservesComment() async throws {
        let store = try FileMetadataStore()
        _ = await store.setComment(path: "movie.mov", comment: "trailer")
        _ = await store.setTypeCreator(
            path: "movie.mov",
            type: HeidrunCore.FourCharCode(string: "MooV"),
            creator: HeidrunCore.FourCharCode(string: "TVOD")
        )

        let row = await store.metadata(path: "movie.mov")
        #expect(row?.type == HeidrunCore.FourCharCode(string: "MooV"))
        #expect(row?.creator == HeidrunCore.FourCharCode(string: "TVOD"))
        #expect(row?.comment == "trailer")
    }

    @Test("rename moves the row from old path to new path")
    func renameMovesRow() async throws {
        let store = try FileMetadataStore()
        _ = await store.setComment(path: "a.txt", comment: "hello")

        _ = await store.rename(from: "a.txt", to: "b.txt")

        #expect(await store.metadata(path: "a.txt") == nil)
        #expect(await store.metadata(path: "b.txt")?.comment == "hello")
    }

    @Test("renameSubtree rewrites both the parent row and every descendant")
    func renameSubtreeRewritesDescendants() async throws {
        let store = try FileMetadataStore()
        _ = await store.setComment(path: "Old", comment: "folder note")
        _ = await store.setComment(path: "Old/inner.txt", comment: "child")
        _ = await store.setComment(path: "Old/sub/deep.txt", comment: "grandchild")
        // Sibling that must NOT be rewritten.
        _ = await store.setComment(path: "Older/keep.txt", comment: "untouched")

        _ = await store.renameSubtree(from: "Old", to: "New")

        #expect(await store.metadata(path: "Old") == nil)
        #expect(await store.metadata(path: "Old/inner.txt") == nil)
        #expect(await store.metadata(path: "New")?.comment == "folder note")
        #expect(await store.metadata(path: "New/inner.txt")?.comment == "child")
        #expect(await store.metadata(path: "New/sub/deep.txt")?.comment == "grandchild")
        // The lookalike sibling is preserved.
        #expect(await store.metadata(path: "Older/keep.txt")?.comment == "untouched")
    }

    @Test("remove drops a single row")
    func removeOne() async throws {
        let store = try FileMetadataStore()
        _ = await store.setComment(path: "x.txt", comment: "x")
        _ = await store.setComment(path: "y.txt", comment: "y")
        _ = await store.remove(path: "x.txt")

        #expect(await store.metadata(path: "x.txt") == nil)
        #expect(await store.metadata(path: "y.txt")?.comment == "y")
    }

    @Test("removeSubtree drops every row at or under the prefix")
    func removeSubtreeDropsBranch() async throws {
        let store = try FileMetadataStore()
        _ = await store.setComment(path: "Doomed", comment: "folder")
        _ = await store.setComment(path: "Doomed/a.txt", comment: "a")
        _ = await store.setComment(path: "Doomed/sub/b.txt", comment: "b")
        _ = await store.setComment(path: "Survivor.txt", comment: "ok")

        _ = await store.removeSubtree(path: "Doomed")

        #expect(await store.metadata(path: "Doomed") == nil)
        #expect(await store.metadata(path: "Doomed/a.txt") == nil)
        #expect(await store.metadata(path: "Doomed/sub/b.txt") == nil)
        #expect(await store.metadata(path: "Survivor.txt")?.comment == "ok")
    }

    @Test("rows persist across re-opening the same DB file")
    func persistAcrossReopen() async throws {
        let dbPath = NSTemporaryDirectory() + "heidrun-meta-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        do {
            let first = try FileMetadataStore(path: dbPath)
            _ = await first.setComment(path: "kept.txt", comment: "survived")
            _ = await first.setTypeCreator(
                path: "kept.txt",
                type: HeidrunCore.FourCharCode(string: "TEXT"),
                creator: HeidrunCore.FourCharCode(string: "ttxt")
            )
        }

        let second = try FileMetadataStore(path: dbPath)
        let row = await second.metadata(path: "kept.txt")
        #expect(row?.comment == "survived")
        #expect(row?.type == HeidrunCore.FourCharCode(string: "TEXT"))
        #expect(row?.creator == HeidrunCore.FourCharCode(string: "ttxt"))
    }
}

@Suite("FileVault metadata integration")
struct FileVaultMetadataIntegrationTests {
    private func makeVault() async throws -> FileVault {
        try FileVault(rootPath: nil, metadata: FileMetadataStore())
    }

    @Test("setComment via FileVault survives a re-read through info(at:)")
    func commentVisibleViaInfo() async throws {
        let vault = try await makeVault()
        let root = await vault.root
        try Data("hi".utf8).write(to: root.appendingPathComponent("note.txt"))

        _ = await vault.setComment(at: [], name: "note.txt", comment: "remember")

        let info = await vault.info(at: [], name: "note.txt")
        #expect(info?.comment == "remember")
    }

    @Test("putFile persists type + creator; later list surfaces them")
    func uploadPersistsTypeCreator() async throws {
        let vault = try await makeVault()

        _ = await vault.putFile(
            at: [],
            name: "song.mp3",
            data: Data([0xFF, 0xFB]),
            type: HeidrunCore.FourCharCode(string: "MP3 "),
            creator: HeidrunCore.FourCharCode(string: "TVOD")
        )

        let entries = await vault.list(at: [])
        let entry = entries?.first(where: { $0.name == "song.mp3" })
        #expect(entry?.type == HeidrunCore.FourCharCode(string: "MP3 "))
        #expect(entry?.creator == HeidrunCore.FourCharCode(string: "TVOD"))
    }

    @Test("renaming a file carries its comment to the new name")
    func renameFollowsComment() async throws {
        let vault = try await makeVault()
        let root = await vault.root
        try Data("hi".utf8).write(to: root.appendingPathComponent("a.txt"))
        _ = await vault.setComment(at: [], name: "a.txt", comment: "keep me")

        _ = await vault.rename(at: [], from: "a.txt", to: "b.txt")

        let info = await vault.info(at: [], name: "b.txt")
        #expect(info?.comment == "keep me")
    }

    @Test("moving a file across folders carries its comment")
    func moveFollowsComment() async throws {
        let vault = try await makeVault()
        let root = await vault.root
        try Data("hi".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Dest", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = await vault.setComment(at: [], name: "a.txt", comment: "movable")

        _ = await vault.move(from: [], name: "a.txt", to: ["Dest"])

        let info = await vault.info(at: ["Dest"], name: "a.txt")
        #expect(info?.comment == "movable")
    }

    @Test("renaming a folder rewrites comments on every descendant file")
    func folderRenameRewritesSubtree() async throws {
        let vault = try await makeVault()
        let root = await vault.root
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: root.appendingPathComponent("Old", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("hi".utf8).write(to: root.appendingPathComponent("Old/inner.txt"))
        _ = await vault.setComment(at: ["Old"], name: "inner.txt", comment: "descendant")

        _ = await vault.rename(at: [], from: "Old", to: "New")

        let info = await vault.info(at: ["New"], name: "inner.txt")
        #expect(info?.comment == "descendant")
    }

    @Test("deleting a file drops its metadata row")
    func deleteDropsRow() async throws {
        let vault = try await makeVault()
        let root = await vault.root
        try Data("hi".utf8).write(to: root.appendingPathComponent("doomed.txt"))
        _ = await vault.setComment(at: [], name: "doomed.txt", comment: "won't last")

        _ = await vault.delete(at: [], name: "doomed.txt")

        // Re-create the file to prove the row really was dropped (a
        // surviving row would surface here on the second info call).
        try Data("hi".utf8).write(to: root.appendingPathComponent("doomed.txt"))
        let info = await vault.info(at: [], name: "doomed.txt")
        #expect(info?.comment == "")
    }
}
