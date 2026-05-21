import Foundation
import HeidrunCore

extension ClientSession {
    /// Reply to `getNewsList` (101) with the joined plain-news feed.
    func handleFetchPlainNews(header: PacketHeader) async {
        let feed = await news.plainFeed()
        try? await writer(PacketEncoder.plainNewsReply(
            taskNumber: header.taskNumber,
            feed: feed,
            encoding: stringEncoding
        ))
    }

    /// Accept a new plain-news post (103), append it under the
    /// poster's nickname, reply empty, then broadcast transID 102 to
    /// every connected client (including the poster — Hotline clients
    /// expect to see their own post echoed).
    func handlePostPlainNews(header: PacketHeader, fields: [PacketField]) async {
        guard let body = fields.string(.message, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 103
            ))
            return
        }
        let stamped = "[\(nickname)] \(body)"
        await news.appendPlainPost(stamped)
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber,
            transactionID: 103
        ))
        await registry.broadcast(PacketEncoder.plainNewsPostPush(
            line: stamped,
            encoding: stringEncoding
        ))
    }
}
