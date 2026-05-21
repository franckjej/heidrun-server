import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle `disconnectUser` (110). Acks the kicker first so the
    /// success reply is observed before the target's TCP drop ripples
    /// through, then disconnects the target by calling its
    /// `disconnectNow()`. `.banFlag` is read but ignored — persistent
    /// ban lists land in v1.5.
    func handleKick(header: PacketHeader, fields: [PacketField]) async {
        let target = fields.uint16(.socket) ?? 0
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber,
            transactionID: 110
        ))
        guard target != 0,
              let session = await registry.lookup(socketID: target) else { return }
        await session.disconnectNow()
    }
}
