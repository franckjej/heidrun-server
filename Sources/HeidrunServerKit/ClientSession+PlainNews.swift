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
        let post = Self.formatPlainNewsPost(nickname: nickname, body: body, date: Date())
        await news.appendPlainPost(post)
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber,
            transactionID: 103
        ))
        await registry.broadcast(PacketEncoder.plainNewsPostPush(
            line: post,
            encoding: stringEncoding
        ))
    }

    /// Render a plain-news post in the classic Hotline "BBS" style:
    /// `From <nick> (<date>):`, a blank line, then the body. Posts are
    /// joined with an underscore hairline by `NewsTree.plainFeed()`.
    /// Newlines are normalised to `\r` (Hotline's line ending).
    static func formatPlainNewsPost(nickname: String, body: String, date: Date) -> String {
        let normalizedBody = body
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        return "From \(nickname) (\(plainNewsDateString(date))):\r\r\(normalizedBody)"
    }

    /// Classic Hotline news date, e.g. `Wed 24/Feb/2026 02:15:18 PM`.
    /// `en_US_POSIX` keeps the rendering stable across server locales.
    static func plainNewsDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE dd/MMM/yyyy hh:mm:ss a"
        return formatter.string(from: date)
    }
}
