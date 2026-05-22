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
    /// initial member fields, and return the assigned ID.
    public func register(
        session: ClientSession,
        nickname: String,
        icon: UInt16
    ) -> UInt16 {
        let assigned = nextSocketID
        nextSocketID &+= 1
        sessions[assigned] = WeakSession(value: session)
        members[assigned] = Member(socketID: assigned, nickname: nickname, icon: icon, status: 0)
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
        for (socket, weakSession) in sessions {
            if let excluded = originator, excluded == socket { continue }
            guard let session = weakSession.value else { continue }
            await session.send(packet)
        }
    }

    private final class WeakSession: @unchecked Sendable {
        weak var value: ClientSession?
        init(value: ClientSession) { self.value = value }
    }
}
