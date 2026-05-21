import Foundation

/// Construction-time config for one `HeidrunServer` instance. Lean by
/// design: MVP only needs a port and a server name to come up. Real
/// config (TOML file, TLS paths, agreement text from disk) lands in
/// Milestone 4. Pass `port: 0` to let the OS pick a free one — useful
/// for integration tests.
public struct ServerConfiguration: Sendable {
    public var port: UInt16
    public var serverName: String
    public var agreement: String?
    public var advertisedVersion: UInt16
    public var newsSeed: NewsTree.Seed?

    public init(
        port: UInt16 = 5500,
        serverName: String = "Heidrun",
        agreement: String? = nil,
        advertisedVersion: UInt16 = 185,
        newsSeed: NewsTree.Seed? = nil
    ) {
        self.port = port
        self.serverName = serverName
        self.agreement = agreement
        self.advertisedVersion = advertisedVersion
        self.newsSeed = newsSeed
    }
}
