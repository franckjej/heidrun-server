import Foundation
import HeidrunCore

/// Read-only view of the server's `filesRoot` directory. M3c.1 only
/// needs `list(at:)` + `info(at:name:)` — uploads, deletions, folder
/// ops, and the HTXF download side-channel land in M3c.2 and M3c.3.
///
/// `rootPath == nil` allocates an ephemeral tempdir on init — useful
/// for tests that want a clean root without managing one themselves.
/// Path components are validated to reject `..`, leading `.`, and
/// any `/` so client requests can't traverse out of the root.
public actor FileVault {
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var type: HeidrunCore.FourCharCode
        public var creator: HeidrunCore.FourCharCode
        public var size: UInt32
        public var itemCount: UInt32

        public init(
            name: String,
            type: HeidrunCore.FourCharCode,
            creator: HeidrunCore.FourCharCode,
            size: UInt32,
            itemCount: UInt32 = 0
        ) {
            self.name = name
            self.type = type
            self.creator = creator
            self.size = size
            self.itemCount = itemCount
        }
    }

    public struct Info: Sendable, Hashable {
        public var entry: Entry
        public var created: Date
        public var modified: Date
        public var comment: String

        public init(entry: Entry, created: Date, modified: Date, comment: String) {
            self.entry = entry
            self.created = created
            self.modified = modified
            self.comment = comment
        }
    }

    /// One node yielded by `enumerate(at:name:)`. Directories carry an
    /// empty `data`; files carry the data-fork bytes ready to frame
    /// into the folder-download stream, plus the resource fork (read
    /// from the `._<name>.rsrc` sidecar, empty when no sidecar exists).
    public struct FolderItem: Sendable, Hashable {
        public var relativePath: [String]
        public var isDirectory: Bool
        public var data: Data
        public var resourceFork: Data
        public var type: HeidrunCore.FourCharCode
        public var creator: HeidrunCore.FourCharCode
        public var created: Date
        public var modified: Date

        public init(
            relativePath: [String],
            isDirectory: Bool,
            data: Data = Data(),
            resourceFork: Data = Data(),
            type: HeidrunCore.FourCharCode = .file,
            creator: HeidrunCore.FourCharCode = .unknown,
            created: Date = .distantPast,
            modified: Date = .distantPast
        ) {
            self.relativePath = relativePath
            self.isDirectory = isDirectory
            self.data = data
            self.resourceFork = resourceFork
            self.type = type
            self.creator = creator
            self.created = created
            self.modified = modified
        }
    }

    private let rootURL: URL
    private let fileManager: FileManager
    /// Persisted per-file metadata (comments + HFS type/creator).
    /// Path-keyed; bind-mounted RAID at `rootURL` is fine because the
    /// metadata DB lives elsewhere and joins are by relative path.
    private let metadata: FileMetadataStore

    public init(
        rootPath: String? = nil,
        fileManager: FileManager = .default,
        metadata: FileMetadataStore
    ) throws {
        self.fileManager = fileManager
        self.metadata = metadata
        if let rootPath {
            self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
                throw FileVaultError.rootNotADirectory(rootPath)
            }
        } else {
            let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "HeidrunServer-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            self.rootURL = tempRoot
        }
    }

    public var root: URL { rootURL }

    /// List entries at the given path. Returns `nil` when the path
    /// doesn't exist, isn't a directory, or contains a forbidden
    /// component. Each entry's HFS type/creator falls back to
    /// `.file/.unknown` when the metadata store has no row — this is
    /// the expected path for files dropped onto the bind-mounted RAID
    /// out-of-band.
    public func list(at path: [String]) async -> [Entry]? {
        guard let directoryURL = resolved(path: path), isDirectory(directoryURL) else { return nil }
        do {
            let children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var entries: [Entry] = []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var built = entry(at: child)
                if built.type != .folder,
                   let row = await metadata.metadata(path: relativeKey(path: path, name: built.name)) {
                    built.type = row.type
                    built.creator = row.creator
                }
                entries.append(built)
            }
            return entries
        } catch {
            return nil
        }
    }

    /// Read the data-fork bytes for a file at `(path, name)`. Returns
    /// `nil` when the entry is missing, a directory, or `name` is
    /// forbidden. Used by the HTXF download side-channel.
    public func bytes(at path: [String], name: String) -> Data? {
        guard Self.isSafeComponent(name) else { return nil }
        guard let parent = resolved(path: path) else { return nil }
        let fileURL = parent.appendingPathComponent(name, isDirectory: false)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir) else { return nil }
        guard !isDir.boolValue else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    /// Read the resource-fork bytes stored alongside the data fork in
    /// the `._<name>.rsrc` sidecar. Returns an empty `Data` when there
    /// is no sidecar (the common case — most files are data-fork only).
    public func resourceFork(at path: [String], name: String) -> Data {
        guard Self.isSafeComponent(name) else { return Data() }
        guard let parent = resolved(path: path) else { return Data() }
        let fileURL = parent.appendingPathComponent(name, isDirectory: false)
        let sidecar = Self.sidecarURL(for: fileURL)
        return (try? Data(contentsOf: sidecar)) ?? Data()
    }

    /// Depth-first walk of the folder at `(path, name)`. Returns a
    /// flat list of every entry inside the folder; directories appear
    /// before their children. The folder itself is *not* part of the
    /// returned list — paths are relative to its root.
    ///
    /// Returns `nil` when the start path doesn't exist, isn't a
    /// directory, or contains a forbidden component.
    public func enumerate(at path: [String], name: String) -> [FolderItem]? {
        guard Self.isSafeComponent(name) else { return nil }
        guard let parent = resolved(path: path) else { return nil }
        let rootURL = parent.appendingPathComponent(name, isDirectory: true)
        guard isDirectory(rootURL) else { return nil }

        var collected: [FolderItem] = []
        Self.walk(url: rootURL, relative: [], into: &collected, fileManager: fileManager)
        return collected
    }

    private static func walk(
        url: URL,
        relative: [String],
        into collected: inout [FolderItem],
        fileManager: FileManager
    ) {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relPath = relative + [child.lastPathComponent]
            let attributes = (try? fileManager.attributesOfItem(atPath: child.path)) ?? [:]
            let created = (attributes[.creationDate] as? Date) ?? .distantPast
            let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
            var isDir: ObjCBool = false
            _ = fileManager.fileExists(atPath: child.path, isDirectory: &isDir)
            if isDir.boolValue {
                collected.append(FolderItem(
                    relativePath: relPath,
                    isDirectory: true,
                    created: created,
                    modified: modified
                ))
                walk(url: child, relative: relPath, into: &collected, fileManager: fileManager)
            } else {
                let data = (try? Data(contentsOf: child)) ?? Data()
                let sidecar = sidecarURL(for: child)
                let resourceFork = (try? Data(contentsOf: sidecar)) ?? Data()
                collected.append(FolderItem(
                    relativePath: relPath,
                    isDirectory: false,
                    data: data,
                    resourceFork: resourceFork,
                    type: .file,
                    creator: .unknown,
                    created: created,
                    modified: modified
                ))
            }
        }
    }

    /// Snapshot metadata for a single entry at `(path, name)`. Returns
    /// `nil` when the entry is missing or `name` is forbidden.
    public func info(at path: [String], name: String) async -> Info? {
        guard Self.isSafeComponent(name) else { return nil }
        guard let parent = resolved(path: path) else { return nil }
        let fileURL = parent.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        var entry = self.entry(at: fileURL)
        let attributes = (try? fileManager.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let created = (attributes[.creationDate] as? Date) ?? .distantPast
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        let stored = await metadata.metadata(path: relativeKey(path: path, name: name))
        if let stored, entry.type != .folder {
            entry.type = stored.type
            entry.creator = stored.creator
        }
        return Info(entry: entry, created: created, modified: modified, comment: stored?.comment ?? "")
    }

    // MARK: - Writes

    /// Delete a file or folder at `(path, name)`. Returns `true` on
    /// success, `false` when the entry is missing or `name` is unsafe.
    @discardableResult
    public func delete(at path: [String], name: String) async -> Bool {
        guard Self.isSafeComponent(name) else { return false }
        guard let parent = resolved(path: path) else { return false }
        let url = parent.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let wasFolder = isDirectory(url)
        do {
            try fileManager.removeItem(at: url)
            if !wasFolder {
                let sidecar = Self.sidecarURL(for: url)
                if fileManager.fileExists(atPath: sidecar.path) {
                    try? fileManager.removeItem(at: sidecar)
                }
            }
            let key = relativeKey(path: path, name: name)
            if wasFolder {
                _ = await metadata.removeSubtree(path: key)
            } else {
                _ = await metadata.remove(path: key)
            }
            return true
        } catch {
            return false
        }
    }

    /// Create a folder at `(path, name)`. Returns `false` when the
    /// folder already exists or the name is unsafe.
    @discardableResult
    public func createFolder(at path: [String], name: String) -> Bool {
        guard Self.isSafeComponent(name) else { return false }
        guard let parent = resolved(path: path) else { return false }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: url.path) else { return false }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            return true
        } catch {
            return false
        }
    }

    /// Rename a file or folder at `(path, oldName)` to `newName`.
    @discardableResult
    public func rename(at path: [String], from oldName: String, to newName: String) async -> Bool {
        guard Self.isSafeComponent(oldName), Self.isSafeComponent(newName) else { return false }
        guard let parent = resolved(path: path) else { return false }
        let source = parent.appendingPathComponent(oldName, isDirectory: false)
        let target = parent.appendingPathComponent(newName, isDirectory: false)
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: target.path) else { return false }
        let wasFolder = isDirectory(source)
        do {
            try fileManager.moveItem(at: source, to: target)
            if !wasFolder {
                Self.moveSidecar(from: source, to: target, fileManager: fileManager)
            }
            let oldKey = relativeKey(path: path, name: oldName)
            let newKey = relativeKey(path: path, name: newName)
            if wasFolder {
                _ = await metadata.renameSubtree(from: oldKey, to: newKey)
            } else {
                _ = await metadata.rename(from: oldKey, to: newKey)
            }
            return true
        } catch {
            return false
        }
    }

    /// Move a file or folder from `(sourcePath, name)` to a different
    /// parent at `destinationPath`. The name is preserved.
    @discardableResult
    public func move(
        from sourcePath: [String],
        name: String,
        to destinationPath: [String]
    ) async -> Bool {
        guard Self.isSafeComponent(name) else { return false }
        guard let sourceParent = resolved(path: sourcePath),
              let destinationParent = resolved(path: destinationPath) else { return false }
        let source = sourceParent.appendingPathComponent(name, isDirectory: false)
        let target = destinationParent.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: source.path),
              isDirectory(destinationParent),
              !fileManager.fileExists(atPath: target.path) else { return false }
        let wasFolder = isDirectory(source)
        do {
            try fileManager.moveItem(at: source, to: target)
            if !wasFolder {
                Self.moveSidecar(from: source, to: target, fileManager: fileManager)
            }
            let oldKey = relativeKey(path: sourcePath, name: name)
            let newKey = relativeKey(path: destinationPath, name: name)
            if wasFolder {
                _ = await metadata.renameSubtree(from: oldKey, to: newKey)
            } else {
                _ = await metadata.rename(from: oldKey, to: newKey)
            }
            return true
        } catch {
            return false
        }
    }

    /// Create a Unix symlink as a stand-in for a Hotline alias.
    @discardableResult
    public func makeAlias(
        from sourcePath: [String],
        name: String,
        to destinationPath: [String]
    ) -> Bool {
        guard Self.isSafeComponent(name) else { return false }
        guard let sourceParent = resolved(path: sourcePath),
              let destinationParent = resolved(path: destinationPath) else { return false }
        let source = sourceParent.appendingPathComponent(name, isDirectory: false)
        let target = destinationParent.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: source.path),
              isDirectory(destinationParent),
              !fileManager.fileExists(atPath: target.path) else { return false }
        do {
            try fileManager.createSymbolicLink(at: target, withDestinationURL: source)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func setComment(at path: [String], name: String, comment: String) async -> Bool {
        guard Self.isSafeComponent(name) else { return false }
        guard let parent = resolved(path: path) else { return false }
        let url = parent.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let key = relativeKey(path: path, name: name)
        _ = await metadata.setComment(path: key, comment: comment)
        return true
    }

    /// Commit an uploaded file's data fork to disk. Used by the HTXF
    /// upload side-channel. Returns `false` when the destination
    /// already exists (and `resume == false`) or the path is unsafe.
    ///
    /// On success, persists `type` / `creator` from the FILP envelope
    /// into the metadata store so a follow-up `info(...)` reads them
    /// back instead of falling through to the `.file/.unknown`
    /// default. Type/creator default to `.file/.unknown` for callers
    /// that don't carry them (resumes mid-stream, legacy tests).
    ///
    /// When `resourceFork` is non-empty the bytes are written to a
    /// `._<name>.rsrc` sidecar next to the data fork; when empty any
    /// existing sidecar from a prior upload is removed (so overwriting
    /// a file with a resource fork with one without doesn't leave a
    /// stale rsrc behind).
    @discardableResult
    public func putFile(
        at path: [String],
        name: String,
        data: Data,
        resourceFork: Data = Data(),
        type: HeidrunCore.FourCharCode = .file,
        creator: HeidrunCore.FourCharCode = .unknown,
        resume: Bool = false
    ) async -> Bool {
        guard Self.isSafeComponent(name) else { return false }
        guard let parent = resolved(path: path), isDirectory(parent) else { return false }
        let url = parent.appendingPathComponent(name, isDirectory: false)
        if resume, fileManager.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                return false
            }
        } else {
            guard !fileManager.fileExists(atPath: url.path) else { return false }
            do {
                try data.write(to: url)
            } catch {
                return false
            }
        }
        // Sidecar: write iff non-empty, otherwise clear any stale one.
        // Resume appends to the data fork and doesn't carry a fresh
        // resource fork — leave any existing sidecar alone.
        if !resume {
            let sidecar = Self.sidecarURL(for: url)
            if resourceFork.isEmpty {
                if fileManager.fileExists(atPath: sidecar.path) {
                    try? fileManager.removeItem(at: sidecar)
                }
            } else {
                try? resourceFork.write(to: sidecar)
            }
        }
        // Persist type/creator (skipped when both are the defaults — no
        // point writing a row that wouldn't change anything an absent
        // row already implies).
        if type != .file || creator != .unknown {
            _ = await metadata.setTypeCreator(
                path: relativeKey(path: path, name: name),
                type: type,
                creator: creator
            )
        }
        return true
    }

    // MARK: - Helpers

    /// Resolve a path-component array into a URL inside the root.
    /// Returns `nil` if any component is unsafe (contains `/`, equals
    /// `..`, or starts with `.`). The empty path resolves to the root.
    private func resolved(path: [String]) -> URL? {
        var url = rootURL
        for component in path {
            guard Self.isSafeComponent(component) else { return nil }
            url.appendPathComponent(component, isDirectory: true)
        }
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Build a wire `Entry` from a child URL. Folders get type `.folder`
    /// and an itemCount; plain files get the catch-all `.file` type +
    /// the file size. HFS type/creator are not preserved by the modern
    /// filesystem, so we don't attempt to read them.
    private func entry(at url: URL) -> Entry {
        let name = url.lastPathComponent
        var isDir: ObjCBool = false
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let count = (try? fileManager.contentsOfDirectory(atPath: url.path).count) ?? 0
            return Entry(
                name: name,
                type: HeidrunCore.FourCharCode.folder,
                creator: HeidrunCore.FourCharCode(rawValue: 0),
                size: 0,
                itemCount: UInt32(count)
            )
        } else {
            let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            let size = UInt32(clamping: (attributes[.size] as? NSNumber)?.intValue ?? 0)
            return Entry(
                name: name,
                type: HeidrunCore.FourCharCode.file,
                creator: HeidrunCore.FourCharCode(rawValue: 0),
                size: size,
                itemCount: 0
            )
        }
    }

    private func relativeKey(path: [String], name: String) -> String {
        (path + [name]).joined(separator: "/")
    }

    /// `..`, `.`, anything containing `/` or `\` is rejected; empty
    /// strings too. Anything else passes — modern filesystems handle
    /// unusual names fine inside `appendPathComponent`.
    public static func isSafeComponent(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        if component == "." || component == ".." { return false }
        if component.contains("/") || component.contains("\\") { return false }
        return true
    }

    /// `<parent>/._<name>.rsrc` — the resource-fork sidecar for the
    /// given data-fork URL. The leading `._` makes the file hidden
    /// (filtered by `.skipsHiddenFiles` in `list(...)` and `walk(...)`),
    /// the `.rsrc` suffix makes the role explicit and avoids collision
    /// with macOS AppleDouble (`._<name>` exactly, no extension).
    static func sidecarURL(for fileURL: URL) -> URL {
        let parent = fileURL.deletingLastPathComponent()
        let name = fileURL.lastPathComponent
        return parent.appendingPathComponent("._\(name).rsrc", isDirectory: false)
    }

    /// Move (or remove) the sidecar that belongs to a file being
    /// renamed/moved. Silent on failure — a missing sidecar is the
    /// common case (data-fork-only files have none).
    static func moveSidecar(from source: URL, to target: URL, fileManager: FileManager) {
        let oldSidecar = sidecarURL(for: source)
        guard fileManager.fileExists(atPath: oldSidecar.path) else { return }
        let newSidecar = sidecarURL(for: target)
        try? fileManager.moveItem(at: oldSidecar, to: newSidecar)
    }
}

public enum FileVaultError: Swift.Error, Equatable {
    case rootNotADirectory(String)
}
