import Foundation

/// Construction-time config for one `HeidrunServer` instance.
public struct ServerConfiguration: Sendable {
    /// Credentials the server should seed on first startup when the
    /// accounts table is empty. `nil` skips the seed entirely.
    public struct BootstrapAdmin: Sendable {
        public var login: String
        public var password: String
        public var nickname: String
        public init(login: String, password: String, nickname: String = "Admin") {
            self.login = login
            self.password = password
            self.nickname = nickname
        }
    }

    public var port: UInt16
    public var serverName: String
    public var agreement: String?
    public var advertisedVersion: UInt16
    public var newsSeed: NewsTree.Seed?
    /// On-disk SQLite path. `nil` = in-memory (default for tests).
    public var accountStorePath: String?
    /// Password-hashing rounds. Production defaults to OWASP's 2023
    /// PBKDF2-SHA256 recommendation (210 000); tests pass a small
    /// number so they don't burn seconds per hash.
    public var passwordRounds: Int
    /// Optional bootstrap admin — seeded by `HeidrunServer.start()` if
    /// the accounts table is empty.
    public var bootstrapAdmin: BootstrapAdmin?

    public init(
        port: UInt16 = 5500,
        serverName: String = "Heidrun",
        agreement: String? = nil,
        advertisedVersion: UInt16 = 185,
        newsSeed: NewsTree.Seed? = nil,
        accountStorePath: String? = nil,
        passwordRounds: Int = PasswordHash.defaultRounds,
        bootstrapAdmin: BootstrapAdmin? = nil
    ) {
        self.port = port
        self.serverName = serverName
        self.agreement = agreement
        self.advertisedVersion = advertisedVersion
        self.newsSeed = newsSeed
        self.accountStorePath = accountStorePath
        self.passwordRounds = passwordRounds
        self.bootstrapAdmin = bootstrapAdmin
    }
}
