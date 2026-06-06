import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle a sendInstantMessage (transID 108). Look up the target
    /// session by socketID, push a transID 104 (`kInfoMsg`) carrying
    /// the sender's socket + message body, then reply to the sender
    /// with `errorID == 0` on delivery or `errorID == 1` if the target
    /// isn't connected.
    func handlePrivateMessage(header: PacketHeader, fields: [PacketField]) async {
        guard hasPrivilege(.sendMessages) else {
            await denyPrivilege(taskNumber: header.taskNumber, transactionID: 108, privilege: "sendMessages")
            return
        }
        let target = fields.uint16(.socket) ?? 0
        guard let body = fields.string(.message, encoding: stringEncoding), target != 0 else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 108
            ))
            return
        }
        guard let session = await registry.lookup(socketID: target) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 108
            ))
            return
        }
        let push = PacketEncoder.privateMessagePush(
            fromSocket: socketID,
            message: body,
            encoding: stringEncoding
        )
        await session.send(push)
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber,
            transactionID: 108
        ))
    }
}
