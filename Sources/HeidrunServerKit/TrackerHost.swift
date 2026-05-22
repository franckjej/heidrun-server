import Foundation

/// One tracker endpoint we should register with.
///
/// Parsed from the mobius-compatible `host[:port][:password]` string form
/// so operator configs are portable between mobius and HeidrunServer:
///
/// ```
/// hltracker.com                          → host="hltracker.com", port=5498, password=""
/// hltracker.com:5500                     → host="hltracker.com", port=5500, password=""
/// private.example:5498:my-tracker-pw     → host="private.example", port=5498, password="my-tracker-pw"
/// ```
///
/// Trailing components default. The host is required; an empty string
/// rejects the parse so a malformed config doesn't silently disable
/// tracker registration for one entry.
public struct TrackerHost: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var password: String

    public init(host: String, port: UInt16 = 5498, password: String = "") {
        self.host = host
        self.port = port
        self.password = password
    }

    /// Parse one config string. Returns `nil` for empty input or for
    /// strings that don't carry a host token (e.g. `":5498"`).
    /// Port that doesn't parse as a UInt16 silently falls back to 5498.
    public static func parse(_ raw: String) -> TrackerHost? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        let host = String(parts[0])
        guard !host.isEmpty else { return nil }
        let port: UInt16 = parts.count > 1
            ? (UInt16(String(parts[1])) ?? 5498)
            : 5498
        let password = parts.count > 2 ? String(parts[2]) : ""
        return TrackerHost(host: host, port: port, password: password)
    }
}
