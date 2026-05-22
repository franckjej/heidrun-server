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
    /// Interface to bind on. Defaults to `0.0.0.0` (all interfaces).
    /// Set to `127.0.0.1` for loopback-only deployments — useful when
    /// the server sits behind a reverse proxy or for local development.
    public var bindHost: String
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
    /// Root directory for the file system. `nil` allocates an
    /// ephemeral tempdir (useful for tests). Production deployments
    /// point this at a persistent location.
    public var filesRootPath: String?
    /// On-disk path for the news state JSON snapshot. `nil` keeps the
    /// in-memory behaviour (state wipes on restart) — useful for
    /// tests; production should point this at a persistent file.
    public var newsStatePath: String?

    public init(
        port: UInt16 = 5500,
        bindHost: String = "0.0.0.0",
        serverName: String = "Heidrun",
        agreement: String? = nil,
        advertisedVersion: UInt16 = 185,
        newsSeed: NewsTree.Seed? = nil,
        accountStorePath: String? = nil,
        passwordRounds: Int = PasswordHash.defaultRounds,
        bootstrapAdmin: BootstrapAdmin? = nil,
        filesRootPath: String? = nil,
        newsStatePath: String? = nil
    ) {
        self.port = port
        self.bindHost = bindHost
        self.serverName = serverName
        self.agreement = agreement
        self.advertisedVersion = advertisedVersion
        self.newsSeed = newsSeed
        self.accountStorePath = accountStorePath
        self.passwordRounds = passwordRounds
        self.bootstrapAdmin = bootstrapAdmin
        self.filesRootPath = filesRootPath
        self.newsStatePath = newsStatePath
    }
}
