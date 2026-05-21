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

    public func snapshot() -> [Member] {
        Array(members.values).sorted { $0.socketID < $1.socketID }
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
