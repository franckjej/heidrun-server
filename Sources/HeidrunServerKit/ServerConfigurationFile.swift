import Foundation
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
    public var serverName: String?
    public var logLevel: String?
    public var dbPath: String?
    public var filesRoot: String?
    public var agreement: String?
    public var bootstrapAdmin: BootstrapAdminFile?

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
        serverName: String? = nil,
        logLevel: String? = nil,
        dbPath: String? = nil,
        filesRoot: String? = nil,
        agreement: String? = nil,
        bootstrapAdmin: BootstrapAdminFile? = nil
    ) {
        self.port = port
        self.serverName = serverName
        self.logLevel = logLevel
        self.dbPath = dbPath
        self.filesRoot = filesRoot
        self.agreement = agreement
        self.bootstrapAdmin = bootstrapAdmin
    }

    enum CodingKeys: String, CodingKey {
        case port
        case serverName = "server_name"
        case logLevel = "log_level"
        case dbPath = "db_path"
        case filesRoot = "files_root"
        case agreement
        case bootstrapAdmin = "bootstrap_admin"
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
        let resolvedServerName = environment["HEIDRUN_SERVER_NAME"]
            ?? serverName
            ?? "Heidrun"
        let resolvedAgreement = environment["HEIDRUN_AGREEMENT"] ?? agreement
        let resolvedDBPath = environment["HEIDRUN_DB_PATH"] ?? dbPath
        let resolvedFilesRoot = environment["HEIDRUN_FILES_ROOT"] ?? filesRoot

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

        return ServerConfiguration(
            port: resolvedPort,
            serverName: resolvedServerName,
            agreement: resolvedAgreement,
            accountStorePath: resolvedDBPath,
            bootstrapAdmin: resolvedAdmin,
            filesRootPath: resolvedFilesRoot
        )
    }
}
