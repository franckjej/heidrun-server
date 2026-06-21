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
        case download(bytes: Data, offset: UInt64)
        /// Pre-assembled FILP/INFO/DATA/MACR envelope for a single-file
        /// download against a session that negotiated
        /// `resourceForkSupport` (Heidrun extension 0xE002). Built once
        /// at TX 202 handler time and streamed unchanged on the side
        /// channel — the HTXF handler doesn't need to know about
        /// framing, it just writes the bytes.
        case framedDownload(envelope: Data)
        case upload(path: [String], name: String, declaredSize: UInt64, resume: Bool)
        /// Server-driven folder download — the enumerated items live
        /// in-memory the same way single-file downloads do (read once
        /// at handler time, replayed on the side channel).
        case folderDownload(items: [FileVault.FolderItem])
        /// Client-driven folder upload — server drains items into the
        /// vault under `(path, name)` for `itemCount` iterations.
        case folderUpload(path: [String], name: String, itemCount: UInt16)
        /// Server banner download (transID 212). Carries the cached
        /// banner bytes the operator configured at server start —
        /// streamed unchanged over the type=2 HTXF preamble.
        case banner(bytes: Data)
    }

    private var pending: [UInt32: Pending] = [:]
    private var nextID: UInt32 = 1

    public init() {}

    /// Register a pending download. Returns the allocated transferID
    /// that the control-channel reply carries back to the client.
    public func registerDownload(bytes: Data, offset: UInt64) -> UInt32 {
        let assigned = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }                    // skip 0; treat as "no transfer"
        pending[assigned] = .download(bytes: bytes, offset: offset)
        return assigned
    }

    /// Register a framed single-file download. `envelope` is the
    /// complete FILP/INFO/DATA/MACR byte stream built at the control-
    /// channel handler — the HTXF handler writes it through unchanged.
    public func registerFramedDownload(envelope: Data) -> UInt32 {
        let assigned = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        pending[assigned] = .framedDownload(envelope: envelope)
        return assigned
    }

    /// Register a pending upload. Returns the allocated transferID
    /// that the control-channel reply carries back to the client.
    public func registerUpload(
        path: [String],
        name: String,
        declaredSize: UInt64,
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

    /// Register a server-driven folder download. The fully-enumerated
    /// item list rides along so the HTXF handler doesn't have to walk
    /// the filesystem again.
    public func registerFolderDownload(items: [FileVault.FolderItem]) -> UInt32 {
        let assigned = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        pending[assigned] = .folderDownload(items: items)
        return assigned
    }

    /// Register a client-driven folder upload. `itemCount` tells the
    /// HTXF handler how many `(header, payload)` cycles to drain.
    public func registerFolderUpload(
        path: [String],
        name: String,
        itemCount: UInt16
    ) -> UInt32 {
        let assigned = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        pending[assigned] = .folderUpload(path: path, name: name, itemCount: itemCount)
        return assigned
    }

    /// Register a server-banner download. The cached bytes ride along
    /// so the HTXF handler can stream them without revisiting disk —
    /// the banner image is loaded into memory once at server start
    /// (see `HeidrunServer.start()`), then handed out unchanged on
    /// every 212 request.
    public func registerBanner(bytes: Data) -> UInt32 {
        let assigned = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        pending[assigned] = .banner(bytes: bytes)
        return assigned
    }

    /// Claim (and remove) a pending transfer. Returns `nil` when no
    /// such ID is registered — e.g. the HTXF handshake arrived twice,
    /// or the client connected with a stale ID.
    public func claim(transferID: UInt32) -> Pending? {
        pending.removeValue(forKey: transferID)
    }

    /// Drop a pending transfer without consuming it. Returns `true`
    /// when an entry existed (the client's `deleteTransfer` (214) made
    /// it through), `false` for unknown IDs.
    @discardableResult
    public func cancel(transferID: UInt32) -> Bool {
        pending.removeValue(forKey: transferID) != nil
    }
}
