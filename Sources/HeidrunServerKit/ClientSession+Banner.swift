import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle `downloadBanner` (212). Reply with the cached banner
    /// bytes' transferID + size + format hint, or an error reply
    /// when no banner is configured. Clients map the error reply
    /// back to `nil` rather than treating it as a hard failure.
    func handleDownloadBanner(header: PacketHeader) async {
        guard let bytes = bannerBytes, !bytes.isEmpty else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 212
            ))
            return
        }
        let transferID = await transfers.registerBanner(bytes: bytes)
        let size = UInt32(clamping: bytes.count)
        try? await writer(PacketEncoder.bannerReply(
            taskNumber: header.taskNumber,
            transferID: transferID,
            transferSize: size,
            bannerKind: bannerKind
        ))
    }
}
