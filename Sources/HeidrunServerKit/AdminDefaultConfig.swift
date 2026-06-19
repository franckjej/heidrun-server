import Foundation

/// Decides where `heidrun-admin` reads its data from when the caller passes
/// no `--config`/`--db` (and no `HEIDRUN_CONFIG`/`HEIDRUN_DB_PATH`), so a
/// common deployment needs no flags. Pure so the precedence is unit-testable;
/// the executable supplies the filesystem probes.
public enum AdminDefaultConfig {
    /// Default config-file locations, in search order.
    public static let configSearchPaths = [
        "/etc/heidrun/heidrun-admin.toml",
        "./heidrun-admin.toml"
    ]

    /// Bind-mount convention accounts-DB path (the `./_data/<db>` layout the
    /// native-host-admin doc uses).
    public static let conventionDBPath = "./_data/heidrun.sqlite"

    public enum Source: Sendable, Equatable {
        /// Load this TOML as the configuration.
        case configFile(String)
        /// Use this path as the accounts DB (siblings derived from it).
        case conventionDB(String)
        /// No default applies — caller was explicit, or nothing was found.
        case none
    }

    /// Choose the default source. `defaultConfigFile` is the first existing
    /// `configSearchPaths` entry (or nil); `conventionDBExists` is whether
    /// `conventionDBPath` is present. An explicit config/db short-circuits to
    /// `.none` so being explicit is never overridden by a stray default file.
    public static func source(
        hasExplicitConfig: Bool,
        hasExplicitDB: Bool,
        defaultConfigFile: String?,
        conventionDBExists: Bool
    ) -> Source {
        guard !hasExplicitConfig, !hasExplicitDB else { return .none }
        if let defaultConfigFile { return .configFile(defaultConfigFile) }
        if conventionDBExists { return .conventionDB(conventionDBPath) }
        return .none
    }

    /// Files-root convention: the `files` directory next to the accounts DB.
    /// Returned only when no `files_root` is set AND that directory exists
    /// (probe supplied by the caller). Display-only — lets `db info` show the
    /// real vault without changing the server's own resolution. `nil` means
    /// "leave files root as it is".
    public static func conventionFilesRoot(
        dbPath: String?,
        currentFilesRoot: String?,
        directoryExists: (String) -> Bool
    ) -> String? {
        guard currentFilesRoot == nil, let dbPath else { return nil }
        let candidate = URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent()
            .appendingPathComponent("files")
            .path
        return directoryExists(candidate) ? candidate : nil
    }
}
