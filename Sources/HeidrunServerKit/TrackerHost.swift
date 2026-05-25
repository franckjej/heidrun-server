import Foundation

/// One tracker endpoint this server registers with.
///
/// Parsed from the `host[:port][:password]` string form:
///
/// ```
/// hltracker.com                          → host="hltracker.com", port=5499, password=""
/// hltracker.com:5499                     → host="hltracker.com", port=5499, password=""
/// private.example:5499:my-tracker-pw     → host="private.example", port=5499, password="my-tracker-pw"
/// ```
///
/// **Port is the UDP registration/discovery port (5499), not 5498.** The
/// Hotline tracker protocol splits the two: clients fetch the server list
/// over **TCP 5498**, while servers send their registration datagrams to
/// **UDP 5499**. Defaulting to 5498 (the list port) means registrations
/// hit a port nothing is listening on for them, and the server silently
/// never appears in any listing — so the default here is 5499.
///
/// Trailing components default. The host is required; an empty string
/// rejects the parse so a malformed config doesn't silently disable
/// tracker registration for one entry.
public struct TrackerHost: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var password: String

    public init(host: String, port: UInt16 = 5499, password: String = "") {
        self.host = host
        self.port = port
        self.password = password
    }

    /// Parse one config string. Returns `nil` for empty input or for
    /// strings that don't carry a host token (e.g. `":5499"`).
    /// A port that doesn't parse as a UInt16 silently falls back to 5499.
    public static func parse(_ raw: String) -> TrackerHost? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        let host = String(parts[0])
        guard !host.isEmpty else { return nil }
        let port: UInt16 = parts.count > 1
            ? (UInt16(String(parts[1])) ?? 5499)
            : 5499
        let password = parts.count > 2 ? String(parts[2]) : ""
        return TrackerHost(host: host, port: port, password: password)
    }
}
