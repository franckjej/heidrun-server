import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle `setClientUserInfo` (304): client is changing its
    /// runtime nickname / icon (no-reply). Update local state and the
    /// registry, then push `userChanged` (301) to everyone else so
    /// their user lists redraw.
    func handleSetClientUserInfo(header: PacketHeader, fields: [PacketField]) async {
        let newNick = fields.string(.nickname, encoding: stringEncoding) ?? nickname
        let newIcon = fields.uint16(.icon) ?? icon
        // Empty string clears; absent field leaves the current value.
        let newEmoji = fields.string(.userEmoji, encoding: .utf8) ?? emoji
        self.nickname = newNick
        self.icon = newIcon
        self.emoji = newEmoji
        guard socketID != 0,
              let updated = await registry.updateMember(
                  socketID: socketID,
                  nickname: newNick,
                  icon: newIcon,
                  emoji: newEmoji
              ) else { return }
        await registry.broadcast(
            PacketEncoder.userChangedPush(member: updated, encoding: stringEncoding),
            excluding: socketID
        )
    }

    /// Handle `broadcast` (355): reply success to the sender and push
    /// the message to every other connected session as a 355 with the
    /// `.message` field. Gated on the `canBroadcast` privilege bit.
    func handleBroadcast(header: PacketHeader, fields: [PacketField]) async {
        guard hasPrivilege(.canBroadcast) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 355
            ))
            return
        }
        let message = fields.string(.message, encoding: stringEncoding) ?? ""
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber,
            transactionID: 355
        ))
        guard !message.isEmpty else { return }
        await registry.broadcast(
            PacketEncoder.serverBroadcastPush(message: message, encoding: stringEncoding),
            excluding: socketID
        )
    }

    /// Handle `deleteNewsBundle` (380): drop the addressed folder or
    /// category. No-reply per the legacy client.
    func handleDeleteNewsBundle(header: PacketHeader, fields: [PacketField]) async {
        guard hasPrivilege(.deleteNewsBundles) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 380, privilege: "deleteNewsBundles")
            return
        }
        let path = newsPathComponents(from: fields)
        guard !path.isEmpty else { return }
        _ = await news.removeBundle(at: path)
    }

    /// Handle `deleteNewsThread` (411): drop one article from a
    /// category. `deleteAll` (337) cascade is not modeled yet — the
    /// single-thread delete covers the common case. No-reply.
    func handleDeleteNewsThread(header: PacketHeader, fields: [PacketField]) async {
        guard hasPrivilege(.deleteArticles) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 411, privilege: "deleteArticles")
            return
        }
        let path = newsPathComponents(from: fields)
        let articleID = Int(fields.uint16(.newsArticleID) ?? 0)
        guard !path.isEmpty, articleID > 0 else { return }
        _ = await news.removePost(at: path, articleID: articleID)
    }

    /// Handle `deleteTransfer` (214): the client gave up on a pending
    /// transfer before the HTXF handshake landed; release the slot.
    /// No-reply.
    func handleDeleteTransfer(header: PacketHeader, fields: [PacketField]) async {
        guard let transferID = fields.uint32(.transferID) else { return }
        await transfers.cancel(transferID: transferID)
    }

    /// Decode a `.newsPath` (325) field into its components. Returns
    /// `[]` (root) when the field is missing or malformed.
    fileprivate func newsPathComponents(from fields: [PacketField]) -> [String] {
        guard let field = fields.first(.newsPath),
              let path = RemotePath(decoding: field.data, encoding: stringEncoding) else {
            return []
        }
        return path.components
    }
}
