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
        agreement: String? = nil,
        bootstrapAdmin: BootstrapAdminFile? = nil,
        trackers: [String]? = nil,
        trackerDescription: String? = nil,
        tlsPort: UInt16? = nil,
        tlsCertificate: String? = nil,
        tlsPrivateKey: String? = nil,
        bannerPath: String? = nil,
        bannerKind: String? = nil
    ) {
        self.port = port
        self.bindHost = bindHost
        self.serverName = serverName
        self.logLevel = logLevel
        self.dbPath = dbPath
        self.filesRoot = filesRoot
        self.newsStatePath = newsStatePath
        self.agreement = agreement
        self.bootstrapAdmin = bootstrapAdmin
        self.trackers = trackers
        self.trackerDescription = trackerDescription
        self.tlsPort = tlsPort
        self.tlsCertificate = tlsCertificate
        self.tlsPrivateKey = tlsPrivateKey
        self.bannerPath = bannerPath
        self.bannerKind = bannerKind
    }

    enum CodingKeys: String, CodingKey {
        case port
        case bindHost = "bind_host"
        case serverName = "server_name"
        case logLevel = "log_level"
        case dbPath = "db_path"
        case filesRoot = "files_root"
        case newsStatePath = "news_state_path"
        case agreement
        case bootstrapAdmin = "bootstrap_admin"
        case trackers
        case trackerDescription = "tracker_description"
        case tlsPort = "tls_port"
        case tlsCertificate = "tls_certificate"
        case tlsPrivateKey = "tls_private_key"
        case bannerPath = "banner_path"
        case bannerKind = "banner_kind"
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

        return ServerConfiguration(
            port: resolvedPort,
            bindHost: resolvedBindHost,
            serverName: resolvedServerName,
            agreement: resolvedAgreement,
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
            bannerKind: resolvedBannerKind
        )
    }
}
