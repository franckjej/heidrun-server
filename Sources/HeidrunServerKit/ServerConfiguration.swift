import Foundation
import HeidrunCore

/// How the server presents its news system. The Hotline protocol has no
/// explicit "news mode" bit — a client chooses threaded vs flat purely
/// from the server's advertised version (`< 151` ⇒ flat pre-1.5 board,
/// `≥ 151` ⇒ threaded). `flat` therefore works by capping the advertised
/// version and refusing threaded transactions.
public enum NewsMode: String, Sendable, CaseIterable {
    /// Threaded categories/bundles/articles for Hotline 1.5+ clients,
    /// with the plain feed still served to legacy clients. Default.
    case threaded
    /// Present as a pre-1.5 server: every client uses the flat bulletin
    /// board (101/103). Caps the advertised version below 151 and
    /// rejects threaded-news transactions.
    case flat

    /// Map an operator-supplied string to a mode. Unknown values fall
    /// back to `.threaded` (the full-featured default); `plain` is an
    /// accepted alias for `flat`.
    public init(parsing raw: String?) {
        switch raw?.lowercased() {
        case "flat", "plain": self = .flat
        default: self = .threaded
        }
    }
}

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
    /// Initial public chat topic (seed). Empty means "no topic" — nothing
    /// is pushed. Overridden by a persisted value once `/topic` has been
    /// used (see `ChatSubjectStore`).
    public var chatSubject: String
    /// JSON persistence path for the live public chat topic. `nil` = no
    /// persistence (topic resets to the config seed each restart).
    public var chatSubjectStatePath: String?
    public var agreement: String?
    public var advertisedVersion: UInt16
    /// Threaded (default) vs flat news. See `NewsMode`.
    public var newsMode: NewsMode

    /// One-shot startup news wipe (`HEIDRUN_NEWS_RESET`). `nil` = no
    /// reset. Operator-driven like `resetAdminPermissions`: set, deploy
    /// once, unset. See `NewsResetScope`.
    public var newsReset: NewsResetScope?

    /// Version actually sent in the login reply. `flat` news caps it
    /// below the Hotline 1.5 threshold (151) so clients use the plain
    /// bulletin board instead of attempting threaded news.
    public var effectiveAdvertisedVersion: UInt16 {
        newsMode == .flat ? min(advertisedVersion, 150) : advertisedVersion
    }

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

    /// Seconds of inbound-packet inactivity before a session flips to
    /// `UserStatusFlags.away` in the broadcast user record. Cleared on
    /// the next packet. `nil` disables idle auto-away.
    public var idleAwayThreshold: TimeInterval?

    /// How often the idle-away supervisor walks the session list. Only
    /// consulted when `idleAwayThreshold` is set.
    public var idleAwayPollInterval: TimeInterval

    /// Wall-clock timestamp the configuration was constructed. Used
    /// by the `/version` chat command as a stand-in for "server
    /// start time" when computing the uptime line — close enough to
    /// process start in practice (configs are loaded immediately
    /// before `HeidrunServer.start()`).
    public var startedAt: Date

    /// One-shot upgrade hook for operators upgrading across the
    /// May 22 2026 commit (`8a78eb1`) that bumped the bootstrap
    /// admin seed from five enforcement bits to
    /// `UserPrivileges.all.rawValue`. When `true`, the server
    /// rewrites the bootstrap admin row's permissions on startup
    /// even if the row already exists (which `bootstrapIfEmpty`
    /// won't touch). Operators flip it on, deploy once, then turn
    /// it back off so subsequent restarts don't clobber operator-
    /// configured permission tightening. Default `false` —
    /// deliberately opt-in.
    public var resetAdminPermissions: Bool

    /// Privacy kill-switch for the `/usershistory` command. When `false`,
    /// `UserEventStore` is never constructed so no join/leave events are
    /// recorded, and the command replies that history is disabled.
    /// Defaults to `true`. Config: `user_history_enabled`; env:
    /// `HEIDRUN_USER_HISTORY` (`0`/`false`/`no`/`off` disables).
    public var userHistoryEnabled: Bool

    /// Opt-in HXD-style **User Access** push. When `true`, the server sends
    /// a TX 354 carrying the connected user's privileges bitmap right after
    /// the login reply, so third-party clients can configure their admin UI
    /// up front (privileges stay server-enforced per request regardless).
    /// **Default `false`:** a privileges-only 354 wipes the roster on Heidrun
    /// clients older than protocol rc18, so enable it only once your client
    /// population is updated. Config: `send_user_access`; env:
    /// `HEIDRUN_SEND_USER_ACCESS` (`1`/`true`/`yes`/`on` enables).
    public var sendUserAccess: Bool

    public init(
        port: UInt16 = 5500,
        bindHost: String = "0.0.0.0",
        serverName: String = "Heidrun",
        chatSubject: String = "",
        chatSubjectStatePath: String? = nil,
        agreement: String? = nil,
        advertisedVersion: UInt16 = 185,
        newsMode: NewsMode = .threaded,
        newsReset: NewsResetScope? = nil,
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
        bannerKind: HeidrunCore.ServerBanner.Kind = .jpeg,
        idleAwayThreshold: TimeInterval? = 600,
        idleAwayPollInterval: TimeInterval = 60,
        startedAt: Date = Date(),
        resetAdminPermissions: Bool = false,
        userHistoryEnabled: Bool = true,
        sendUserAccess: Bool = false
    ) {
        self.port = port
        self.bindHost = bindHost
        self.serverName = serverName
        self.chatSubject = chatSubject
        self.chatSubjectStatePath = chatSubjectStatePath
        self.agreement = agreement
        self.advertisedVersion = advertisedVersion
        self.newsMode = newsMode
        self.newsReset = newsReset
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
        self.idleAwayThreshold = idleAwayThreshold
        self.idleAwayPollInterval = idleAwayPollInterval
        self.startedAt = startedAt
        self.resetAdminPermissions = resetAdminPermissions
        self.userHistoryEnabled = userHistoryEnabled
        self.sendUserAccess = sendUserAccess
    }
}
