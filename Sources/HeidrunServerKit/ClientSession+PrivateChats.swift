import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle `createPrivateChat` (112): allocate a new room with the
    /// caller as the only initial member, reply with the chatReference
    /// so the creator can join their own room, and push an invitation
    /// (113) to the addressed target (if any).
    func handleCreatePrivateChat(header: PacketHeader, fields: [PacketField]) async {
        guard hasPrivilege(.initiatePrivateChat) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 112, privilege: "initiatePrivateChat")
            return
        }
        let target = fields.uint16(.socket) ?? 0
        let chatID = await privateChats.create(creator: socketID)
        let chatRefData = ChatID(rawValue: chatID).data
        if target != 0 {
            let invitation = PacketEncoder.privateChatInvitePush(
                chatReference: chatRefData,
                fromSocket: socketID,
                message: "\(nickname) invites you to chat",
                encoding: stringEncoding
            )
            if let session = await registry.lookup(socketID: target) {
                await session.send(invitation)
            }
        }
        let reply = PacketCodec.encode(
            classID: 1,
            transactionID: 112,
            taskNumber: header.taskNumber,
            fields: [PacketField(key: .chatReference, data: chatRefData)]
        )
        try? await writer(reply)
    }

    /// Handle `inviteToPrivateChat` (113): push an invitation to the
    /// target for an already-allocated room. No-reply.
    func handleInviteToPrivateChat(header: PacketHeader, fields: [PacketField]) async {
        let target = fields.uint16(.socket) ?? 0
        guard let ref = fields.first(.chatReference), target != 0 else { return }
        let invitation = PacketEncoder.privateChatInvitePush(
            chatReference: ref.data,
            fromSocket: socketID,
            message: "\(nickname) invites you to chat",
            encoding: stringEncoding
        )
        if let session = await registry.lookup(socketID: target) {
            await session.send(invitation)
        }
    }

    /// Handle `rejectPrivateChat` (114): invitations aren't held
    /// server-side, so there's nothing to drop. No-reply, no work.
    func handleRejectPrivateChat(header: PacketHeader, fields: [PacketField]) async {
        // Intentionally empty. Kept as an explicit handler so the
        // dispatch table doesn't hide the transaction behind a silent
        // default case.
    }

    /// Handle `joinPrivateChat` (115): add this connection to the
    /// room, push a 117 for every existing member to the joiner so
    /// their roster populates, then push a 117 carrying the joiner to
    /// every existing member so theirs updates too. No-reply.
    func handleJoinPrivateChat(header: PacketHeader, fields: [PacketField]) async {
        guard let ref = fields.first(.chatReference) else { return }
        let chatID = ChatID(data: ref.data).rawValue
        let existing = await privateChats.members(id: chatID).subtracting([socketID])
        await privateChats.join(id: chatID, socket: socketID)

        let allMembers = await registry.snapshot()
        // Hydrate the joiner's roster.
        for socket in existing {
            guard let member = allMembers.first(where: { $0.socketID == socket }) else { continue }
            let push = PacketEncoder.privateChatJoinedPush(
                chatReference: ref.data,
                member: member,
                encoding: stringEncoding
            )
            if let session = await registry.lookup(socketID: socketID) {
                await session.send(push)
            }
        }
        // Announce the joiner to everybody already in the room.
        if let me = allMembers.first(where: { $0.socketID == socketID }) {
            let push = PacketEncoder.privateChatJoinedPush(
                chatReference: ref.data,
                member: me,
                encoding: stringEncoding
            )
            for socket in existing {
                if let session = await registry.lookup(socketID: socket) {
                    await session.send(push)
                }
            }
        }
    }

    /// Handle `leavePrivateChat` (116): drop membership, push a 118
    /// to every remaining member. No-reply.
    func handleLeavePrivateChat(header: PacketHeader, fields: [PacketField]) async {
        guard let ref = fields.first(.chatReference) else { return }
        let chatID = ChatID(data: ref.data).rawValue
        let remaining = await privateChats.members(id: chatID).subtracting([socketID])
        await privateChats.leave(id: chatID, socket: socketID)
        let push = PacketEncoder.privateChatLeftPush(
            chatReference: ref.data,
            socket: socketID
        )
        for socket in remaining {
            if let session = await registry.lookup(socketID: socket) {
                await session.send(push)
            }
        }
    }

    /// Handle `setPrivateChatSubject` (120): store the new subject and
    /// push 119 to everyone else in the room. No-reply.
    func handleSetPrivateChatSubject(header: PacketHeader, fields: [PacketField]) async {
        guard let ref = fields.first(.chatReference) else { return }
        let chatID = ChatID(data: ref.data).rawValue
        let subject = fields.string(.chatSubject, encoding: stringEncoding) ?? ""
        await privateChats.setSubject(id: chatID, subject: subject)
        let push = PacketEncoder.privateChatSubjectPush(
            chatReference: ref.data,
            subject: subject,
            encoding: stringEncoding
        )
        let members = await privateChats.members(id: chatID).subtracting([socketID])
        for socket in members {
            if let session = await registry.lookup(socketID: socket) {
                await session.send(push)
            }
        }
    }
}
