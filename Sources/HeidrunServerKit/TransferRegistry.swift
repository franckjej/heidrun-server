import Foundation

/// Tracks pending file transfers between the control-channel transaction
/// that registers them (e.g. `downloadFile` (202)) and the side-channel
/// HTXF connection that fulfils them.
///
/// Transfer IDs are server-allocated UInt32 values returned in the
/// control reply. The HTXF connection opens to the transfer port,
/// sends a 16-byte preamble carrying that ID, and the server `claim`s
/// the pending entry to drive the stream. A claim is one-shot — the
/// entry is removed on retrieval so duplicate handshakes fail clean.
public actor TransferRegistry {
    public enum Pending: Sendable {
        case download(bytes: Data, offset: UInt32)
        case upload(path: [String], name: String, declaredSize: UInt32, resume: Bool)
    }

    private var pending: [UInt32: Pending] = [:]
    private var nextID: UInt32 = 1

    public init() {}

    /// Register a pending download. Returns the allocated transferID
    /// that the control-channel reply carries back to the client.
    public func registerDownload(bytes: Data, offset: UInt32) -> UInt32 {
        let assigned = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }                    // skip 0; treat as "no transfer"
        pending[assigned] = .download(bytes: bytes, offset: offset)
        return assigned
    }

    /// Register a pending upload. Returns the allocated transferID
    /// that the control-channel reply carries back to the client.
    public func registerUpload(
        path: [String],
        name: String,
        declaredSize: UInt32,
        resume: Bool
    ) -> UInt32 {
        let assigned = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        pending[assigned] = .upload(
            path: path,
            name: name,
            declaredSize: declaredSize,
            resume: resume
        )
        return assigned
    }

    /// Claim (and remove) a pending transfer. Returns `nil` when no
    /// such ID is registered — e.g. the HTXF handshake arrived twice,
    /// or the client connected with a stale ID.
    public func claim(transferID: UInt32) -> Pending? {
        pending.removeValue(forKey: transferID)
    }
}
