import Foundation
import HeidrunCore

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
    /// Trackers this server should periodically register with. Empty
    /// list disables tracker registration entirely. See `TrackerHost`
    /// for the mobius-compatible `host[:port][:password]` shape.
    public var trackers: [TrackerHost]
    /// Description shown in tracker listings. Falls back to
    /// `serverName` when unset so an unconfigured server still gets a
    /// readable directory entry.
    public var trackerDescription: String?
    /// Control-channel port for the TLS sibling listener. The TLS
    /// transfer port is always `tlsPort + 1`. `nil` skips TLS entirely
    /// and the server binds only the cleartext pair. Conventional
    /// production value is `5502` (cleartext 5500, TLS 5502).
    public var tlsPort: UInt16?
    /// PEM-encoded certificate chain (server cert + any intermediates).
    /// Required when `tlsPort` is set.
    public var tlsCertificatePath: String?
    /// PEM-encoded private key matching `tlsCertificatePath`. Required
    /// when `tlsPort` is set.
    public var tlsPrivateKeyPath: String?
    /// Server-banner image surfaced to clients via the 212
    /// `downloadBanner` transaction. `nil` disables the banner —
    /// 212 requests return an error reply, which clients map to
    /// "no banner configured". Read once at `start()`, cached in
    /// memory; an operator updating the image needs to restart the
    /// container (same workflow as the TLS cert).
    public var bannerPath: String?
    /// Format hint sent in the 212 reply's `bannerType` field (152).
    /// Defaults to `.jpeg` since every modern client supports JPEG
    /// + every banner ever shipped happened to be one. Override for
    /// GIF / BMP / PICT / URL deployments.
    public var bannerKind: HeidrunCore.ServerBanner.Kind

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
        newsStatePath: String? = nil,
        trackers: [TrackerHost] = [],
        trackerDescription: String? = nil,
        tlsPort: UInt16? = nil,
        tlsCertificatePath: String? = nil,
        tlsPrivateKeyPath: String? = nil,
        bannerPath: String? = nil,
        bannerKind: HeidrunCore.ServerBanner.Kind = .jpeg
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
        self.trackers = trackers
        self.trackerDescription = trackerDescription
        self.tlsPort = tlsPort
        self.tlsCertificatePath = tlsCertificatePath
        self.tlsPrivateKeyPath = tlsPrivateKeyPath
        self.bannerPath = bannerPath
        self.bannerKind = bannerKind
    }
}
