import Foundation
import GRDB
import HeidrunCore

/// One persisted metadata row for a file in `FileVault`. Folders and
/// files that have never been touched by the metadata-aware code paths
/// have no row — the lookup just returns `nil` and callers fall back to
/// "type=.file, creator=.unknown, comment=''".
public struct FileMetadata: Sendable, Hashable {
    public var path: String
    public var type: HeidrunCore.FourCharCode
    public var creator: HeidrunCore.FourCharCode
    public var comment: String

    public init(
        path: String,
        type: HeidrunCore.FourCharCode = .file,
        creator: HeidrunCore.FourCharCode = .unknown,
        comment: String = ""
    ) {
        self.path = path
        self.type = type
        self.creator = creator
        self.comment = comment
    }
}

/// GRDB-backed persistence for per-file metadata.
///
/// Keyed by the file's path relative to `FileVault`'s root, joined by
/// `/`. The store is intentionally separate from the on-disk file tree
/// — operators can bind-mount a multi-TB RAID at `HEIDRUN_FILES_ROOT`
/// while this metadata DB lives next to the accounts DB on a small
/// persistent volume. Files dropped onto the RAID out-of-band have no
/// rows here; the listing just falls back to defaults.
///
/// Lifecycle alignment with `FileVault`:
/// * `delete` is called when a file is removed.
/// * `rename` (single row) is called when a file is renamed in place.
/// * `renameSubtree` is called when a *folder* is renamed or moved —
///   every descendant row gets its path prefix rewritten in one UPDATE.
///
/// Concurrent access with `AccountStore`: both actors open the same
/// SQLite file via separate `DatabaseQueue` handles. SQLite's
/// file-level locking serialises writes; the workload here (a handful
/// of writes per upload / rename / delete) doesn't justify WAL mode.
public actor FileMetadataStore {
    private let dbQueue: DatabaseQueue

    /// Open the DB at `path` (or in-memory when `path == nil`). Runs
    /// the metadata schema migration before returning so callers can
    /// hit it immediately. `path` can point at the same file
    /// `AccountStore` uses — the two stores' migrations are namespaced
    /// (`v1_file_metadata` here vs. `v1_accounts` there) so they
    /// coexist in one DB without colliding.
    public init(path: String? = nil) throws {
        if let path {
            self.dbQueue = try DatabaseQueue(path: path)
        } else {
            self.dbQueue = try DatabaseQueue()
        }
        try Self.runMigrations(on: dbQueue)
    }

    // MARK: - Reads

    /// Snapshot the metadata row for `path`, or `nil` when no row
    /// exists. Errors (DB unreachable, schema mismatch) collapse to
    /// `nil` — the caller already needs the fallback path for
    /// "filesystem touched out-of-band", so a transient DB failure
    /// looks identical from the protocol's POV.
    public func metadata(path: String) -> FileMetadata? {
        guard let row = try? dbQueue.read({ database in
            try Row.fetchOne(
                database,
                sql: "SELECT path, type_code, creator, comment FROM file_metadata WHERE path = ?",
                arguments: [path]
            )
        }) else {
            return nil
        }
        let typeRaw: Int64 = row["type_code"] ?? 0
        let creatorRaw: Int64 = row["creator"] ?? 0
        return FileMetadata(
            path: row["path"] ?? path,
            type: FourCharCode(rawValue: UInt32(truncatingIfNeeded: typeRaw)),
            creator: FourCharCode(rawValue: UInt32(truncatingIfNeeded: creatorRaw)),
            comment: row["comment"] ?? ""
        )
    }

    // MARK: - Writes

    /// Upsert just the comment for `path`. Empty `comment` removes the
    /// row only if no other field is set; otherwise it persists the
    /// row with a blank comment so prior type/creator survive.
    @discardableResult
    public func setComment(path: String, comment: String) -> Bool {
        let existing = metadata(path: path)
        if comment.isEmpty, existing?.type == .file || existing?.type == nil,
           existing?.creator == .unknown || existing?.creator == nil {
            // Nothing left worth persisting — drop the row.
            return remove(path: path)
        }
        let type = existing?.type ?? .file
        let creator = existing?.creator ?? .unknown
        return upsert(path: path, type: type, creator: creator, comment: comment)
    }

    /// Upsert type + creator for `path`. Keeps any existing comment.
    @discardableResult
    public func setTypeCreator(path: String, type: HeidrunCore.FourCharCode, creator: HeidrunCore.FourCharCode) -> Bool {
        let comment = metadata(path: path)?.comment ?? ""
        return upsert(path: path, type: type, creator: creator, comment: comment)
    }

    /// Replace every field for `path` in one go. Used by the upload
    /// commit path where the FILP envelope carries type/creator and
    /// the comment defaults to empty.
    @discardableResult
    public func setAll(
        path: String,
        type: HeidrunCore.FourCharCode,
        creator: HeidrunCore.FourCharCode,
        comment: String
    ) -> Bool {
        upsert(path: path, type: type, creator: creator, comment: comment)
    }

    /// Move a single row from `oldPath` to `newPath`. Used for file
    /// renames + moves. Returns `true` when a row was rewritten or the
    /// no-op succeeded (no row at oldPath → still success).
    @discardableResult
    public func rename(from oldPath: String, to newPath: String) -> Bool {
        guard oldPath != newPath else { return true }
        do {
            try dbQueue.write { database in
                // DELETE any conflicting row at newPath first, then
                // rewrite. Mirrors the wider FileVault behaviour where
                // the filesystem move would have failed if newPath
                // existed — but we still want a deterministic outcome
                // if the metadata DB somehow has stale rows.
                try database.execute(
                    sql: "DELETE FROM file_metadata WHERE path = ?",
                    arguments: [newPath]
                )
                try database.execute(
                    sql: "UPDATE file_metadata SET path = ?, updated_at = ? WHERE path = ?",
                    arguments: [newPath, Int64(Date().timeIntervalSince1970), oldPath]
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// Rewrite the path prefix on every row under `oldPrefix` to
    /// `newPrefix`. Used when a *folder* is renamed or moved — every
    /// descendant's row needs to follow the parent in one transaction
    /// so a crash mid-rename can't leave half the subtree orphaned.
    ///
    /// `oldPrefix` and `newPrefix` are *bare* path strings without
    /// trailing slashes (e.g. `"foo/bar"`, not `"foo/bar/"`). The
    /// UPDATE matches `path = '<old>'` exactly or `path LIKE '<old>/%'`
    /// for descendants.
    @discardableResult
    public func renameSubtree(from oldPrefix: String, to newPrefix: String) -> Bool {
        guard oldPrefix != newPrefix else { return true }
        let oldPattern = oldPrefix + "/%"
        let prefixLength = Int64(oldPrefix.count + 1) // +1 to skip the "/"
        do {
            try dbQueue.write { database in
                // First, rewrite descendants: keep their relative tail
                // and prepend the new parent. SQLite's substr is
                // 1-based; the column-only form lets us splice strings
                // without pulling rows into Swift.
                try database.execute(
                    sql: """
                    UPDATE file_metadata
                       SET path = ? || '/' || substr(path, ?),
                           updated_at = ?
                     WHERE path LIKE ?
                    """,
                    arguments: [
                        newPrefix,
                        prefixLength + 1, // substr starts past the "<old>/"
                        Int64(Date().timeIntervalSince1970),
                        oldPattern
                    ]
                )
                // Then rewrite the parent row itself if present.
                try database.execute(
                    sql: "UPDATE file_metadata SET path = ?, updated_at = ? WHERE path = ?",
                    arguments: [newPrefix, Int64(Date().timeIntervalSince1970), oldPrefix]
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// Drop the row at `path`. Used when a file is deleted. No-op when
    /// no row exists.
    @discardableResult
    public func remove(path: String) -> Bool {
        do {
            try dbQueue.write { database in
                try database.execute(
                    sql: "DELETE FROM file_metadata WHERE path = ?",
                    arguments: [path]
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// Drop every row under `path` plus the row at `path` itself. Used
    /// when a folder is deleted (recursive remove on disk).
    @discardableResult
    public func removeSubtree(path: String) -> Bool {
        do {
            try dbQueue.write { database in
                try database.execute(
                    sql: "DELETE FROM file_metadata WHERE path = ? OR path LIKE ?",
                    arguments: [path, path + "/%"]
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// Diagnostic count of metadata rows. Useful in tests; not used in
    /// the dispatch path.
    public func count() -> Int {
        (try? dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM file_metadata") ?? 0
        }) ?? 0
    }

    // MARK: - Internals

    @discardableResult
    private func upsert(
        path: String,
        type: HeidrunCore.FourCharCode,
        creator: HeidrunCore.FourCharCode,
        comment: String
    ) -> Bool {
        do {
            try dbQueue.write { database in
                try database.execute(
                    sql: """
                    INSERT INTO file_metadata (path, type_code, creator, comment, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        type_code = excluded.type_code,
                        creator = excluded.creator,
                        comment = excluded.comment,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        path,
                        Int64(type.rawValue),
                        Int64(creator.rawValue),
                        comment,
                        Int64(Date().timeIntervalSince1970)
                    ]
                )
            }
            return true
        } catch {
            return false
        }
    }

    private static func runMigrations(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_file_metadata") { database in
            try database.execute(sql: """
                CREATE TABLE file_metadata (
                    path TEXT PRIMARY KEY,
                    type_code INTEGER NOT NULL DEFAULT 0,
                    creator INTEGER NOT NULL DEFAULT 0,
                    comment TEXT NOT NULL DEFAULT '',
                    updated_at INTEGER NOT NULL
                )
                """)
            // The PK alone covers point lookups + the LIKE 'prefix/%'
            // subtree queries — SQLite uses the same B-tree.
        }
        try migrator.migrate(queue)
    }
}
