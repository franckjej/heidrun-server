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
    public static let version: String = "0.7.0"

    /// Short build identifier — typically the 7-char git SHA stamped
    /// at Docker build time via `HEIDRUN_BUILD`. Returns `"dev"` when
    /// unset or empty after sanitisation.
    public static var buildIdentifier: String {
        sanitised(ProcessInfo.processInfo.environment["HEIDRUN_BUILD"], fallback: "dev")
    }

    /// ISO-8601 build date stamped at Docker build time via
    /// `HEIDRUN_BUILD_DATE`. Empty when unset — the `/version` reply
    /// omits the parenthetical date in that case.
    public static var buildDate: String {
        sanitised(ProcessInfo.processInfo.environment["HEIDRUN_BUILD_DATE"], fallback: "")
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

    /// Strip ASCII control bytes from the raw value so a malformed
    /// build stamp can't corrupt the multi-line `/version` chat reply
    /// (an embedded `\r` would render as two lines on the wire).
    /// Returns `fallback` when the input is `nil` or empty after
    /// stripping.
    private static func sanitised(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let cleaned = raw.filter {
            !$0.isASCII || ($0.asciiValue ?? 0) >= 0x20
        }
        return cleaned.isEmpty ? fallback : cleaned
    }
}
