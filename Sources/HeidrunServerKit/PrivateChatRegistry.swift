import Foundation

/// In-memory store of open private-chat rooms. Each room is keyed by
/// the 4-byte `chatReference` the client sees on the wire; membership
/// is a set of socketIDs from `UserRegistry`. Rooms vanish once the
/// last member leaves.
public actor PrivateChatRegistry {
    struct Room {
        let id: UInt32
        var members: Set<UInt16>
        var subject: String = ""
    }

    private var rooms: [UInt32: Room] = [:]
    /// Monotonic id source. Starts at a value mature Hotline servers
    /// historically used so log lines are easy to spot.
    private var nextID: UInt32 = 0x1000_0001

    public init() {}

    /// Allocate a new room with `creator` as the only initial member.
    /// Returns the assigned id (mirrored to the client as a 4-byte
    /// `chatReference`).
    public func create(creator: UInt16) -> UInt32 {
        let id = nextID
        nextID &+= 1
        rooms[id] = Room(id: id, members: [creator])
        return id
    }

    /// Add `socket` to an existing room. Returns `false` when the id
    /// isn't known.
    @discardableResult
    public func join(id: UInt32, socket: UInt16) -> Bool {
        guard var room = rooms[id] else { return false }
        room.members.insert(socket)
        rooms[id] = room
        return true
    }

    /// Remove `socket` from `id`. Drops the room when the last member
    /// leaves so id slots get reclaimed.
    public func leave(id: UInt32, socket: UInt16) {
        guard var room = rooms[id] else { return }
        room.members.remove(socket)
        if room.members.isEmpty {
            rooms[id] = nil
        } else {
            rooms[id] = room
        }
    }

    /// Replace a room's subject. No-op on unknown ids.
    public func setSubject(id: UInt32, subject: String) {
        guard var room = rooms[id] else { return }
        room.subject = subject
        rooms[id] = room
    }

    /// Member snapshot. Empty for unknown rooms so callers can treat
    /// the response as "nothing to fan out to".
    public func members(id: UInt32) -> Set<UInt16> {
        rooms[id]?.members ?? []
    }

    /// Drop `socket` from every room it belonged to. Returns the
    /// `(id, remaining-members)` pairs the caller still needs to
    /// notify with a `privateChatLeft` (118) push so other rosters
    /// stay accurate.
    public func evictFromAll(socket: UInt16) -> [(id: UInt32, remaining: Set<UInt16>)] {
        var notifications: [(id: UInt32, remaining: Set<UInt16>)] = []
        for (id, room) in rooms where room.members.contains(socket) {
            var updated = room
            updated.members.remove(socket)
            if updated.members.isEmpty {
                rooms[id] = nil
            } else {
                rooms[id] = updated
                notifications.append((id, updated.members))
            }
        }
        return notifications
    }
}
