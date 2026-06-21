import Foundation

/// Server version + build identifiers surfaced through the `/version`
/// chat command and (eventually) log lines / status endpoints.
///
/// The semver string is hand-maintained per release. The build
/// identifier and build date are read from environment variables that
/// the Dockerfile stamps at image build time — set
/// `HEIDRUN_BUILD=$(git rev-parse --short HEAD)` and
/// `HEIDRUN_BUILD_DATE=$(date -u +%Y-%m-%d)` to control them.
/// Unstamped environments (local `swift run`, unit tests) see
/// `dev` and an empty date.
public enum HeidrunServerInfo {
    /// Semantic version of HeidrunServer. Bumped manually each
    /// release.
    public static let version: String = "1.3.0"

    /// Short build identifier — typically the 7-char git SHA. Lookup
    /// order:
    ///
    /// 1. `HEIDRUN_BUILD` env var (CI / explicit override).
    /// 2. The file `<HEIDRUN_BUILD_INFO_DIR>/build-id` — the Dockerfile's
    ///    `git-info` stage writes this so any image built from a git
    ///    checkout auto-stamps without operator action.
    /// 3. `"dev"` fallback for local `swift run` and any other
    ///    unstamped environment.
    public static var buildIdentifier: String {
        if let value = resolveBuildField(
            envVar: "HEIDRUN_BUILD",
            fileName: "build-id"
        ) {
            return value
        }
        return "dev"
    }

    /// ISO-8601 build date stamped alongside the build identifier.
    /// Same three-tier lookup as `buildIdentifier`; empty when nothing
    /// is configured, in which case the `/version` reply omits the
    /// parenthetical date entirely.
    public static var buildDate: String {
        resolveBuildField(
            envVar: "HEIDRUN_BUILD_DATE",
            fileName: "build-date"
        ) ?? ""
    }

    /// Shared resolution: env var (non-empty) wins; otherwise read the
    /// matching file under `HEIDRUN_BUILD_INFO_DIR` when that env var
    /// is set. Returns the sanitised value, or `nil` when neither
    /// source yielded usable bytes.
    private static func resolveBuildField(
        envVar: String,
        fileName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let raw = environment[envVar], !raw.isEmpty {
            let cleaned = sanitiseControl(raw)
            if !cleaned.isEmpty { return cleaned }
        }
        if let dir = environment["HEIDRUN_BUILD_INFO_DIR"],
           let contents = try? String(contentsOfFile: "\(dir)/\(fileName)", encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = sanitiseControl(trimmed)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// ASCII-control-byte filter shared by both env-var and file
    /// sources. A malformed stamp can't smuggle a `\r` into the
    /// multi-line `/version` reply.
    private static func sanitiseControl(_ raw: String) -> String {
        raw.filter {
            !$0.isASCII || ($0.asciiValue ?? 0) >= 0x20
        }
    }

    /// Swift language mode the binary was built against. Derived from
    /// the `#if swift(>=X.Y)` compile-time guard ladder so the value
    /// reflects what the binary was actually compiled with — no
    /// runtime detection or build-arg stamping needed.
    public static var swiftCompilerVersion: String {
        #if swift(>=6.3)
        return "6.3"
        #elseif swift(>=6.2)
        return "6.2"
        #elseif swift(>=6.1)
        return "6.1"
        #elseif swift(>=6.0)
        return "6.0"
        #else
        return "<6.0"
        #endif
    }

    /// Short human-readable platform string: "Linux <PRETTY_NAME>" from
    /// `/etc/os-release` on Linux, "macOS <major.minor.patch>" on macOS,
    /// or `"unknown"` on anything else. Read lazily — cheap, and
    /// re-read on every access (`/version` is called rarely).
    public static var platformDescription: String {
        #if os(Linux)
        if let contents = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                guard line.hasPrefix("PRETTY_NAME=") else { continue }
                let raw = line.dropFirst("PRETTY_NAME=".count)
                let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return "Linux \(trimmed)"
            }
        }
        return "Linux"
        #elseif os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        return "unknown"
        #endif
    }

    /// Format an uptime duration as `Xd Yh Zm` / `Yh Zm` / `Zm` —
    /// trimming leading zero units so a fresh process shows `0m`
    /// rather than `0d 0h 0m`. Sub-minute granularity isn't useful at
    /// the chat level.
    public static func formatUptime(since start: Date) -> String {
        let totalSeconds = max(0, Int(Date().timeIntervalSince(start)))
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
