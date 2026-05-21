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

    private let rootURL: URL
    private let fileManager: FileManager

    public init(
        rootPath: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
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
    /// component.
    public func list(at path: [String]) -> [Entry]? {
        guard let directoryURL = resolved(path: path), isDirectory(directoryURL) else { return nil }
        do {
            let children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return children
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map(entry(at:))
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

    /// Snapshot metadata for a single entry at `(path, name)`. Returns
    /// `nil` when the entry is missing or `name` is forbidden.
    public func info(at path: [String], name: String) -> Info? {
        guard Self.isSafeComponent(name) else { return nil }
        guard let parent = resolved(path: path) else { return nil }
        let fileURL = parent.appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let entry = self.entry(at: fileURL)
        let attributes = (try? fileManager.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let created = (attributes[.creationDate] as? Date) ?? .distantPast
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        return Info(entry: entry, created: created, modified: modified, comment: "")
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

    /// `..`, `.`, anything containing `/` or `\` is rejected; empty
    /// strings too. Anything else passes — modern filesystems handle
    /// unusual names fine inside `appendPathComponent`.
    public static func isSafeComponent(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        if component == "." || component == ".." { return false }
        if component.contains("/") || component.contains("\\") { return false }
        return true
    }
}

public enum FileVaultError: Swift.Error, Equatable {
    case rootNotADirectory(String)
}
