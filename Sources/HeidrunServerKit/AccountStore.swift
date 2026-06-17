import Foundation
import GRDB

/// GRDB-backed account persistence. Wraps a `DatabaseQueue` (in-memory
/// or on disk) plus a `DatabaseMigrator` that runs the `accounts`
/// schema migration on startup. Every public method snapshots rows out
/// to plain `Account` value types — callers never see GRDB's row API.
///
/// Password hashing rounds are configurable so tests can drop to a
/// fast count while production uses `PasswordHash.defaultRounds`.
public actor AccountStore {
    public enum AccountStoreError: Swift.Error, Equatable {
        case loginAlreadyExists(String)
    }

    private let dbQueue: DatabaseQueue
    private let passwordRounds: Int

    /// Open an on-disk DB at `path`, or an in-memory DB when `path == nil`.
    /// Runs migrations before returning so the store is immediately ready.
    public init(
        path: String? = nil,
        passwordRounds: Int = PasswordHash.defaultRounds
    ) throws {
        if let path {
            self.dbQueue = try DatabaseQueue(path: path)
        } else {
            self.dbQueue = try DatabaseQueue()
        }
        self.passwordRounds = passwordRounds
        try Self.runMigrations(on: dbQueue)
    }

    // MARK: - CRUD

    /// Create a new account. Throws `loginAlreadyExists` on UNIQUE
    /// collision; PBKDF2 hashing is done before the INSERT so failures
    /// from a bad password don't leave the table half-populated.
    @discardableResult
    public func create(
        login: String,
        password: String,
        nickname: String,
        iconID: UInt16 = 0,
        permissions: UInt64 = 0
    ) throws -> Account {
        let phc = try PasswordHash.hash(password, rounds: passwordRounds)
        let now = Date()
        return try dbQueue.write { database in
            do {
                try database.execute(
                    sql: """
                    INSERT INTO accounts
                        (login, nickname, password_hash, icon_id, permissions, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        login,
                        nickname,
                        phc,
                        Int(iconID),
                        Int64(bitPattern: UInt64(permissions)),
                        Int(now.timeIntervalSince1970),
                        Int(now.timeIntervalSince1970)
                    ]
                )
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                throw AccountStoreError.loginAlreadyExists(login)
            }
            return Account(
                id: database.lastInsertedRowID,
                login: login,
                nickname: nickname,
                passwordHash: phc,
                iconID: iconID,
                permissions: permissions,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    public func get(login: String) throws -> Account? {
        try dbQueue.read { database in
            try Self.fetchOne(login: login, on: database)
        }
    }

    @discardableResult
    public func delete(login: String) throws -> Bool {
        try dbQueue.write { database in
            try database.execute(
                sql: "DELETE FROM accounts WHERE login = ?",
                arguments: [login]
            )
            return database.changesCount > 0
        }
    }

    /// Update the mutable subset of an account (nickname, icon, permissions,
    /// and optionally the password). Returns the updated snapshot, or
    /// `nil` when no row with that login exists.
    @discardableResult
    public func update(
        login: String,
        nickname: String?,
        iconID: UInt16?,
        permissions: UInt64?,
        newPassword: String?
    ) throws -> Account? {
        let newHash: String?
        if let newPassword {
            newHash = try PasswordHash.hash(newPassword, rounds: passwordRounds)
        } else {
            newHash = nil
        }
        return try dbQueue.write { database in
            guard let current = try Self.fetchOne(login: login, on: database) else { return nil }
            let resolvedNickname = nickname ?? current.nickname
            let resolvedIcon = iconID ?? current.iconID
            let resolvedPerms = permissions ?? current.permissions
            let resolvedHash = newHash ?? current.passwordHash
            let now = Date()
            try database.execute(
                sql: """
                UPDATE accounts
                SET nickname = ?, icon_id = ?, permissions = ?, password_hash = ?, updated_at = ?
                WHERE login = ?
                """,
                arguments: [
                    resolvedNickname,
                    Int(resolvedIcon),
                    Int64(bitPattern: UInt64(resolvedPerms)),
                    resolvedHash,
                    Int(now.timeIntervalSince1970),
                    login
                ]
            )
            return Account(
                id: current.id,
                login: login,
                nickname: resolvedNickname,
                passwordHash: resolvedHash,
                iconID: resolvedIcon,
                permissions: resolvedPerms,
                createdAt: current.createdAt,
                updatedAt: now
            )
        }
    }

    /// Look up `login` and verify the given password against the stored
    /// PHC string. Returns the `Account` on success, `nil` on missing
    /// login or wrong password.
    public func verifyCredentials(login: String, password: String) throws -> Account? {
        guard let account = try get(login: login) else { return nil }
        return PasswordHash.verify(password, hashedPHC: account.passwordHash) ? account : nil
    }

    public func count() throws -> Int {
        try dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM accounts") ?? 0
        }
    }

    /// All accounts, ordered by login. Snapshots every row to plain
    /// `Account` values — used by the admin CLI's `account list`.
    public func list() throws -> [Account] {
        try dbQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT id, login, nickname, password_hash, icon_id, permissions, created_at, updated_at
                FROM accounts ORDER BY login ASC
                """
            )
            return rows.map { row in
                let storedPermissions: Int64 = row["permissions"]
                return Account(
                    id: row["id"],
                    login: row["login"],
                    nickname: row["nickname"],
                    passwordHash: row["password_hash"],
                    iconID: UInt16(clamping: row["icon_id"] as Int),
                    permissions: UInt64(bitPattern: storedPermissions),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at"] as Int))
                )
            }
        }
    }

    /// If the accounts table is empty, seed a single account with the
    /// given credentials. Idempotent — called from server startup so
    /// fresh DBs come up with an admin account ready to log in. Returns
    /// `true` when the seed actually inserted a row.
    @discardableResult
    public func bootstrapIfEmpty(
        login: String,
        password: String,
        nickname: String,
        permissions: UInt64
    ) throws -> Bool {
        guard try count() == 0 else { return false }
        _ = try create(
            login: login,
            password: password,
            nickname: nickname,
            iconID: 0,
            permissions: permissions
        )
        return true
    }

    /// Insert an account with the given login only if no row with that
    /// login currently exists. Idempotent across restarts; pre-existing
    /// rows keep their stored fields (especially `permissions`) so
    /// operator adjustments via `modifyLogin` survive subsequent boots.
    /// Returns `true` when this call actually inserted a row.
    ///
    /// Distinct from `bootstrapIfEmpty`: that method seeds the *first*
    /// row in a fresh DB; this one seeds a *specific* missing login
    /// against an already-populated table — used by the guest seed
    /// that needs to coexist with a previously-seeded admin row.
    @discardableResult
    public func ensureExists(
        login: String,
        password: String,
        nickname: String,
        permissions: UInt64
    ) throws -> Bool {
        if try get(login: login) != nil { return false }
        _ = try create(
            login: login,
            password: password,
            nickname: nickname,
            iconID: 0,
            permissions: permissions
        )
        return true
    }

    // MARK: - Migrations

    private static func runMigrations(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_accounts") { database in
            try database.execute(sql: """
                CREATE TABLE accounts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    login TEXT NOT NULL UNIQUE,
                    nickname TEXT NOT NULL,
                    password_hash TEXT NOT NULL,
                    icon_id INTEGER NOT NULL DEFAULT 0,
                    permissions INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """)
            try database.execute(sql: "CREATE INDEX accounts_login_idx ON accounts(login)")
        }
        try migrator.migrate(queue)
    }

    private static func fetchOne(login: String, on database: Database) throws -> Account? {
        let row = try Row.fetchOne(
            database,
            sql: """
            SELECT id, login, nickname, password_hash, icon_id, permissions, created_at, updated_at
            FROM accounts WHERE login = ?
            """,
            arguments: [login]
        )
        guard let row else { return nil }
        let storedPermissions: Int64 = row["permissions"]
        return Account(
            id: row["id"],
            login: row["login"],
            nickname: row["nickname"],
            passwordHash: row["password_hash"],
            iconID: UInt16(clamping: row["icon_id"] as Int),
            permissions: UInt64(bitPattern: Int64(storedPermissions)),
            createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at"] as Int))
        )
    }
}
