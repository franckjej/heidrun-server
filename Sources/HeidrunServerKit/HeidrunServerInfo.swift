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
