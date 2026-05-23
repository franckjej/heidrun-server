import Foundation
import HeidrunCore

/// Holds the live user roster and orchestrates fan-out to every
/// connected session. Sessions register themselves on login, deregister
/// on disconnect. The actor's main job is to mint a unique 16-bit
/// `socketID` (Hotline's per-server user identifier), keep a `(socketID
/// → ClientSession)` map, and offer a `broadcast` helper that writes
/// the same packet to every member (optionally excluding the
/// originator).
public actor UserRegistry {
    /// Lightweight projection of a connected user. Snapshotted out of
    /// the registry on demand so callers don't hold the actor across
    /// `await` boundaries.
    public struct Member: Sendable, Hashable {
        public let socketID: UInt16
        public var nickname: String
        public var icon: UInt16
        public var status: UInt16
    }

    private var nextSocketID: UInt16 = 1
    private var sessions: [UInt16: WeakSession] = [:]
    private var members: [UInt16: Member] = [:]

    public init() {}

    /// Mint a unique `socketID`, store the (weakly-held) session and
    /// initial member fields, and return the assigned ID. `status` is
    /// the two-byte `hotStatus` (color + flags) the client should see
    /// in `userListEntry` records — admins typically pass a non-zero
    /// value so the red name + admin flag are baked into the broadcast.
    public func register(
        session: ClientSession,
        nickname: String,
        icon: UInt16,
        status: UInt16 = 0
    ) -> UInt16 {
        let assigned = nextSocketID
        nextSocketID &+= 1
        sessions[assigned] = WeakSession(value: session)
        members[assigned] = Member(socketID: assigned, nickname: nickname, icon: icon, status: status)
        return assigned
    }

    public func unregister(socketID: UInt16) {
        sessions.removeValue(forKey: socketID)
        members.removeValue(forKey: socketID)
    }

    /// Replace the public-facing nickname / icon for an existing
    /// session. Called from the `setClientUserInfo` (304) handler so
    /// the next `getUserList` snapshot reflects the change. Returns
    /// the updated `Member` (or `nil` if the socket isn't registered)
    /// so the caller can fan out a `userChanged` (301) push.
    @discardableResult
    public func updateMember(socketID: UInt16, nickname: String, icon: UInt16) -> Member? {
        guard var existing = members[socketID] else { return nil }
        existing.nickname = nickname
        existing.icon = icon
        members[socketID] = existing
        return existing
    }

    /// Patch only the two-byte `hotStatus` on an existing member.
    /// Returns the updated `Member` so the caller can fan out a
    /// `userChanged` (301) push. Used by the idle-away supervisor.
    @discardableResult
    public func updateMemberStatus(socketID: UInt16, status: UInt16) -> Member? {
        guard var existing = members[socketID] else { return nil }
        existing.status = status
        members[socketID] = existing
        return existing
    }

    /// All currently-registered `ClientSession` instances, paired with
    /// their socket IDs. Used by background supervisors (idle-away)
    /// that need to inspect or update per-session state without going
    /// through the broadcast path.
    public func liveSessions() -> [(socketID: UInt16, session: ClientSession)] {
        sessions.compactMap { socket, weakSession in
            guard let session = weakSession.value else { return nil }
            return (socket, session)
        }
    }

    public func snapshot() -> [Member] {
        Array(members.values).sorted { $0.socketID < $1.socketID }
    }

    /// Look up the live `ClientSession` for a given `socketID`, or
    /// `nil` if no such session is currently connected. Used by
    /// targeted transactions (private message, kick) that need to
    /// deliver bytes to a single peer rather than broadcasting.
    public func lookup(socketID: UInt16) -> ClientSession? {
        sessions[socketID]?.value
    }

    /// Send `packet` to every live session. `excluding` is the
    /// originator's `socketID`; pass `nil` to deliver to everyone.
    public func broadcast(_ packet: Data, excluding originator: UInt16? = nil) async {
        var delivered = 0
        for (socket, weakSession) in sessions {
            if let excluded = originator, excluded == socket { continue }
            guard let session = weakSession.value else { continue }
            await session.send(packet)
            delivered += 1
        }
        serverLogger.debug("broadcast", metadata: [
            "delivered": "\(delivered)",
            "excluding": originator.map { "\($0)" } ?? "none",
            "bytes": "\(packet.count)"
        ])
    }

    private final class WeakSession: @unchecked Sendable {
        weak var value: ClientSession?
        init(value: ClientSession) { self.value = value }
    }
}
