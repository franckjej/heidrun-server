import Foundation
import HeidrunCore
import TOMLKit

/// Persistent on-disk shape of `ServerConfiguration` — loaded by the
/// executable via `--config` / `HEIDRUN_CONFIG`. Every field is
/// optional; missing keys fall back to the built-in defaults, and env
/// vars override the file. Override precedence is **env var > file >
/// default**.
///
/// Example `/etc/heidrun-server.toml`:
///
/// ```toml
/// port = 5500
/// server_name = "Heidrun"
/// log_level = "info"
/// agreement = "Welcome to the server. Be kind."
///
/// db_path = "/var/lib/heidrun/heidrun.sqlite"
/// files_root = "/var/lib/heidrun/files"
///
/// [bootstrap_admin]
/// login = "admin"
/// password = "admin"
/// nickname = "Admin"
/// ```
public struct ServerConfigurationFile: Codable, Sendable {
    public var port: UInt16?
    public var bindHost: String?
    public var serverName: String?
    public var logLevel: String?
    public var dbPath: String?
    public var filesRoot: String?
    public var newsStatePath: String?
    /// News mode: `"threaded"` (default) or `"flat"` (`"plain"` alias).
    /// See `NewsMode`. Unknown values fall back to threaded.
    public var newsMode: String?
    public var agreement: String?
    public var bootstrapAdmin: BootstrapAdminFile?
    /// Mobius-style tracker endpoints, each `host[:port][:password]`.
    /// Empty / missing disables tracker registration.
    public var trackers: [String]?
    /// Free-text description rendered in tracker listings. Falls back
    /// to `serverName` if missing.
    public var trackerDescription: String?
    /// Control-channel TLS sibling port. Missing / 0 disables TLS.
    public var tlsPort: UInt16?
    /// Path to the PEM cert chain for the TLS listener.
    public var tlsCertificate: String?
    /// Path to the PEM private key for the TLS listener.
    public var tlsPrivateKey: String?
    /// Path to the server banner image (JPEG / GIF / BMP / PICT).
    /// Loaded into memory at startup; `nil` disables the banner.
    public var bannerPath: String?
    /// `bannerType` field (152) sent in the 212 reply. One of
    /// `"url"`, `"jpeg"`, `"gif"`, `"bmp"`, `"pict"`. Defaults to
    /// "jpeg" when the field is omitted but `banner_path` is set.
    public var bannerKind: String?
    /// Seconds of inbound-packet inactivity before a session flips to
    /// the `.away` flag on its broadcast user record. Cleared on the
    /// next packet. `0` (or omitted-then-0) disables idle auto-away.
    /// Defaults to 600 (10 minutes).
    public var idleAwayThreshold: Int?
    /// How often (seconds) the supervisor walks the live session list.
    /// Defaults to 60.
    public var idleAwayPollInterval: Int?
    /// One-shot upgrade hook — when `true`, the server rewrites the
    /// bootstrap admin row's permissions to `UserPrivileges.all` on
    /// startup even if the row already exists. Use to recover from
    /// the pre-`8a78eb1` (May 22 2026) seed where the admin only got
    /// 5 enforcement bits. Off by default; flip on, deploy, flip
    /// off so subsequent restarts don't clobber operator edits.
    public var resetAdminPermissions: Bool?

    public struct BootstrapAdminFile: Codable, Sendable {
        public var login: String?
        public var password: String?
        public var nickname: String?

        public init(
            login: String? = nil,
            password: String? = nil,
            nickname: String? = nil
        ) {
            self.login = login
            self.password = password
            self.nickname = nickname
        }
    }

    public init(
        port: UInt16? = nil,
        bindHost: String? = nil,
        serverName: String? = nil,
        logLevel: String? = nil,
        dbPath: String? = nil,
        filesRoot: String? = nil,
        newsStatePath: String? = nil,
        newsMode: String? = nil,
        agreement: String? = nil,
        bootstrapAdmin: BootstrapAdminFile? = nil,
        trackers: [String]? = nil,
        trackerDescription: String? = nil,
        tlsPort: UInt16? = nil,
        tlsCertificate: String? = nil,
        tlsPrivateKey: String? = nil,
        bannerPath: String? = nil,
        bannerKind: String? = nil,
        idleAwayThreshold: Int? = nil,
        idleAwayPollInterval: Int? = nil,
        resetAdminPermissions: Bool? = nil
    ) {
        self.port = port
        self.bindHost = bindHost
        self.serverName = serverName
        self.logLevel = logLevel
        self.dbPath = dbPath
        self.filesRoot = filesRoot
        self.newsStatePath = newsStatePath
        self.newsMode = newsMode
        self.agreement = agreement
        self.bootstrapAdmin = bootstrapAdmin
        self.trackers = trackers
        self.trackerDescription = trackerDescription
        self.tlsPort = tlsPort
        self.tlsCertificate = tlsCertificate
        self.tlsPrivateKey = tlsPrivateKey
        self.bannerPath = bannerPath
        self.bannerKind = bannerKind
        self.idleAwayThreshold = idleAwayThreshold
        self.idleAwayPollInterval = idleAwayPollInterval
        self.resetAdminPermissions = resetAdminPermissions
    }

    enum CodingKeys: String, CodingKey {
        case port
        case bindHost = "bind_host"
        case serverName = "server_name"
        case logLevel = "log_level"
        case dbPath = "db_path"
        case filesRoot = "files_root"
        case newsStatePath = "news_state_path"
        case newsMode = "news_mode"
        case agreement
        case bootstrapAdmin = "bootstrap_admin"
        case trackers
        case trackerDescription = "tracker_description"
        case tlsPort = "tls_port"
        case tlsCertificate = "tls_certificate"
        case tlsPrivateKey = "tls_private_key"
        case bannerPath = "banner_path"
        case bannerKind = "banner_kind"
        case idleAwayThreshold = "idle_away_threshold"
        case idleAwayPollInterval = "idle_away_poll_interval"
        case resetAdminPermissions = "reset_admin_permissions"
    }

    public enum LoadError: Swift.Error, Equatable {
        case unreadable(path: String)
        case malformed(reason: String)
    }

    /// Read + decode a TOML file at `path`. Throws `LoadError` for any
    /// failure so the executable can surface a useful log line.
    public static func load(from path: String) throws -> ServerConfigurationFile {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw LoadError.unreadable(path: path)
        }
        do {
            return try TOMLDecoder().decode(ServerConfigurationFile.self, from: text)
        } catch {
            throw LoadError.malformed(reason: "\(error)")
        }
    }

    /// Apply env-var overrides on top of the file. Missing-everywhere
    /// fields fall back to the built-in defaults baked into
    /// `ServerConfiguration.init`.
    public func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ServerConfiguration {
        let resolvedPort: UInt16 = {
            if let raw = environment["HEIDRUN_PORT"], let parsed = UInt16(raw) {
                return parsed
            }
            return port ?? 5500
        }()
        let resolvedBindHost = environment["HEIDRUN_BIND_HOST"]
            ?? bindHost
            ?? "0.0.0.0"
        let resolvedServerName = environment["HEIDRUN_SERVER_NAME"]
            ?? serverName
            ?? "Heidrun"
        let resolvedAgreement = environment["HEIDRUN_AGREEMENT"] ?? agreement
        let resolvedDBPath = environment["HEIDRUN_DB_PATH"] ?? dbPath
        let resolvedFilesRoot = environment["HEIDRUN_FILES_ROOT"] ?? filesRoot
        let resolvedNewsStatePath: String? = {
            if let raw = environment["HEIDRUN_NEWS_PATH"] { return raw }
            if let explicit = newsStatePath { return explicit }
            // Derive from the DB path: <stem>.news.json next to the
            // SQLite file. Keeps related state in one directory and
            // avoids one more env var operators have to set.
            guard let dbPath = resolvedDBPath else { return nil }
            let url = URL(fileURLWithPath: dbPath)
            return url.deletingPathExtension()
                .appendingPathExtension("news.json")
                .path
        }()

        // News mode — env wins over file; unknown values fall back to
        // threaded inside `NewsMode(parsing:)`.
        let resolvedNewsMode = NewsMode(parsing: environment["HEIDRUN_NEWS_MODE"] ?? newsMode)

        let resolvedAdmin = ServerConfiguration.BootstrapAdmin(
            login: environment["HEIDRUN_ADMIN_LOGIN"]
                ?? bootstrapAdmin?.login
                ?? "admin",
            password: environment["HEIDRUN_ADMIN_PASSWORD"]
                ?? bootstrapAdmin?.password
                ?? "admin",
            nickname: environment["HEIDRUN_ADMIN_NICKNAME"]
                ?? bootstrapAdmin?.nickname
                ?? "Admin"
        )

        // Trackers — env var (comma-separated) wins over file. Each raw
        // entry is parsed via TrackerHost.parse; malformed entries drop
        // silently rather than failing the whole startup.
        let rawTrackers: [String] = {
            if let raw = environment["HEIDRUN_TRACKERS"] {
                return raw.split(separator: ",", omittingEmptySubsequences: true)
                    .map(String.init)
            }
            return trackers ?? []
        }()
        let resolvedTrackers = rawTrackers.compactMap(TrackerHost.parse)
        let resolvedTrackerDescription = environment["HEIDRUN_TRACKER_DESCRIPTION"]
            ?? trackerDescription

        // TLS — all three pieces (port, cert, key) need to be present
        // to enable the sibling listener. A missing piece keeps TLS
        // off; a partially-configured deploy (port set but no cert)
        // surfaces as a critical startup error in HeidrunServer.start
        // rather than silently running cleartext-only.
        let resolvedTLSPort: UInt16? = {
            if let raw = environment["HEIDRUN_TLS_PORT"], let parsed = UInt16(raw), parsed > 0 {
                return parsed
            }
            return (tlsPort.flatMap { $0 > 0 ? $0 : nil })
        }()
        let resolvedTLSCertificate = environment["HEIDRUN_TLS_CERTIFICATE"] ?? tlsCertificate
        let resolvedTLSPrivateKey = environment["HEIDRUN_TLS_PRIVATE_KEY"] ?? tlsPrivateKey

        // Banner — env var wins over file. Path drives whether the
        // banner is offered at all; kind is just a format hint (152)
        // sent in the 212 reply, mapped from a lowercased string.
        let resolvedBannerPath = environment["HEIDRUN_BANNER_PATH"] ?? bannerPath
        let resolvedBannerKindRaw = (environment["HEIDRUN_BANNER_KIND"] ?? bannerKind)?
            .lowercased()
        let resolvedBannerKind: HeidrunCore.ServerBanner.Kind = {
            switch resolvedBannerKindRaw {
            case "url":  return .url
            case "jpeg", "jpg": return .jpeg
            case "gif":  return .gif
            case "bmp":  return .bmp
            case "pict": return .pict
            default:     return .jpeg
            }
        }()

        // Idle-away — env wins over file. `0` disables; defaults to
        // the built-in (`ServerConfiguration.init`) values when nothing
        // is set anywhere.
        let resolvedIdleThreshold: TimeInterval? = {
            if let raw = environment["HEIDRUN_IDLE_AWAY_THRESHOLD"], let parsed = Int(raw) {
                return parsed > 0 ? TimeInterval(parsed) : nil
            }
            if let fileValue = idleAwayThreshold {
                return fileValue > 0 ? TimeInterval(fileValue) : nil
            }
            return 600
        }()
        // Reset hook — env var wins, accepts "1"/"true"/"yes" (any case)
        // as truthy; everything else is false. Defaults to file value,
        // then `false` if the file is silent too.
        let resolvedReset: Bool = {
            if let raw = environment["HEIDRUN_RESET_ADMIN_PERMISSIONS"] {
                switch raw.lowercased() {
                case "1", "true", "yes", "on": return true
                default: return false
                }
            }
            return resetAdminPermissions ?? false
        }()

        let resolvedIdlePoll: TimeInterval = {
            if let raw = environment["HEIDRUN_IDLE_AWAY_POLL"], let parsed = Int(raw), parsed > 0 {
                return TimeInterval(parsed)
            }
            if let fileValue = idleAwayPollInterval, fileValue > 0 {
                return TimeInterval(fileValue)
            }
            return 60
        }()

        return ServerConfiguration(
            port: resolvedPort,
            bindHost: resolvedBindHost,
            serverName: resolvedServerName,
            agreement: resolvedAgreement,
            newsMode: resolvedNewsMode,
            accountStorePath: resolvedDBPath,
            bootstrapAdmin: resolvedAdmin,
            filesRootPath: resolvedFilesRoot,
            newsStatePath: resolvedNewsStatePath,
            trackers: resolvedTrackers,
            trackerDescription: resolvedTrackerDescription,
            tlsPort: resolvedTLSPort,
            tlsCertificatePath: resolvedTLSCertificate,
            tlsPrivateKeyPath: resolvedTLSPrivateKey,
            bannerPath: resolvedBannerPath,
            bannerKind: resolvedBannerKind,
            idleAwayThreshold: resolvedIdleThreshold,
            idleAwayPollInterval: resolvedIdlePoll,
            resetAdminPermissions: resolvedReset
        )
    }
}
