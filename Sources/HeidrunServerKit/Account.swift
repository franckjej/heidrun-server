import Foundation

/// One row in the `accounts` SQLite table. Value-type by design —
/// `AccountStore` snapshots accounts on read and consumers never mutate
/// them directly; updates go back through the store.
public struct Account: Sendable, Hashable {
    public var id: Int64
    public var login: String
    public var nickname: String
    public var passwordHash: String         // PHC-style string from `PasswordHash`
    public var iconID: UInt16
    /// 64-bit privilege bitfield. Hotline 1.x uses the low 32 bits; we
    /// reserve the upper half for future grants without a schema bump.
    public var permissions: UInt64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64 = 0,
        login: String,
        nickname: String,
        passwordHash: String,
        iconID: UInt16 = 0,
        permissions: UInt64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.login = login
        self.nickname = nickname
        self.passwordHash = passwordHash
        self.iconID = iconID
        self.permissions = permissions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Classic Hotline privilege bits — mirrors the wire `accessPrivs`
/// field exactly. Bit positions are taken from `HeidrunCore`'s
/// `UserPrivileges` so the `permissions` stored here can be sent
/// straight back on the wire as an 8-byte privilege blob.
public enum AccountPrivilege: UInt64, Sendable {
    case createAccounts        = 0x00004000     // 1 << 14 (createUser)
    case deleteAccounts        = 0x00008000     // 1 << 15 (deleteUser)
    case readAccounts          = 0x00010000     // 1 << 16 (readUser)  → openLogin (352)
    case modifyAccounts        = 0x00020000     // 1 << 17 (modifyUser)
    case disconnectUsers       = 0x00400000     // 1 << 22 (disconnectUsers) → kick (110)
}

extension Account {
    /// `true` when the account has every privilege in `required` set.
    public func has(_ required: AccountPrivilege) -> Bool {
        permissions & required.rawValue == required.rawValue
    }

    /// `true` when this account holds an admin-level capability that
    /// should surface as a visible status marker (red name + admin
    /// flag) in clients. Currently keyed off `disconnectUsers` — the
    /// classic "you can kick people" privilege used by every Hotline
    /// admin role since the original Mac client.
    public var isAdmin: Bool {
        has(.disconnectUsers)
    }

    /// Two-byte `hotStatus` value to embed in `userListEntry` / `userChanged`
    /// records for this account. High byte = colour palette index, low
    /// byte = flag bitmask. Admins surface as palette 36 (#ff0000) +
    /// the `admin` flag so clients honouring either signal paint the
    /// row red.
    public var initialHotStatus: UInt16 {
        guard isAdmin else { return 0 }
        // Palette ID 36, admin flag (1 << 1) — matches the classic Hotline
        // admin appearance.
        let color: UInt16 = 36
        let flags: UInt16 = 1 << 1
        return (color << 8) | flags
    }
}

extension Account? {
    /// Convenience: guests (no account) report no status flags / colour.
    /// Authenticated accounts use their own `initialHotStatus`.
    public var initialHotStatus: UInt16 {
        self?.initialHotStatus ?? 0
    }
}
