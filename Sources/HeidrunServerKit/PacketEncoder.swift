import Foundation
import HeidrunCore

/// Builders for every packet `HeidrunServer` emits in Milestone 2.
/// Each function returns the raw bytes ready to write to the wire.
enum PacketEncoder {
    /// Server's reply to a login (transID 107). Carries the advertised
    /// protocol version, the assigned socket ID, and the server's
    /// display name.
    static func loginReply(
        taskNumber: UInt32,
        advertisedVersion: UInt16,
        socketID: UInt16,
        serverName: String,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 1,
            transactionID: 107,
            taskNumber: taskNumber,
            fields: [
                PacketField.uint16(.clientVersion, advertisedVersion),
                PacketField.uint16(.socket, socketID),
                PacketField.string(.serverName, serverName, encoding: encoding)
            ]
        )
    }

    /// Empty reply to acknowledge a transaction without payload — used
    /// for the chat-send ack (105 reply) and similar fire-and-forget
    /// transactions that the client still tracks by taskNumber.
    static func emptyReply(taskNumber: UInt32, transactionID: UInt16) -> Data {
        PacketCodec.encode(
            classID: 1,
            transactionID: transactionID,
            taskNumber: taskNumber,
            fields: []
        )
    }

    /// Reply to a `getUserList` (300) request — one `userListEntry`
    /// field per connected user.
    static func userListReply(
        taskNumber: UInt32,
        members: [UserRegistry.Member],
        encoding: String.Encoding
    ) -> Data {
        let fields = members.map { member in
            UserListEntryCodec.encode(
                User(
                    socket: member.socketID,
                    icon: member.icon,
                    status: UserStatus(rawValue: member.status),
                    privileges: [],
                    nickname: member.nickname
                ),
                encoding: encoding
            )
        }
        return PacketCodec.encode(
            classID: 1,
            transactionID: 300,
            taskNumber: taskNumber,
            fields: fields
        )
    }

    /// Push transID 301 (`userChanged`) describing a connected user's
    /// current profile. Fan-out via `UserRegistry.broadcast`.
    static func userChangedPush(
        member: UserRegistry.Member,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 301,
            taskNumber: 0,
            fields: [
                PacketField.uint16(.socket, member.socketID),
                PacketField.uint16(.icon, member.icon),
                PacketField.uint16(.status, member.status),
                PacketField.string(.nickname, member.nickname, encoding: encoding)
            ]
        )
    }

    /// Push transID 302 (`userLeft`) for the given socket. Sent to
    /// every remaining session when a connection drops.
    static func userLeftPush(socketID: UInt16) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 302,
            taskNumber: 0,
            fields: [PacketField.uint16(.socket, socketID)]
        )
    }

    /// Push transID 106 (`chatMessage`) — the formatted chat line goes
    /// to every connected session, including the originator (so the
    /// sender sees their own message echoed and confirms it landed).
    static func chatPush(
        line: String,
        isAction: Bool,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 106,
            taskNumber: 0,
            fields: [
                PacketField.string(.message, line, encoding: encoding),
                PacketField.uint16(.parameter, isAction ? 1 : 0)
            ]
        )
    }

    /// Push transID 104 (`kInfoMsg`) — server-to-target delivery of a
    /// private message. Fields: sender's socket + the body.
    static func privateMessagePush(
        fromSocket: UInt16,
        message: String,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 104,
            taskNumber: 0,
            fields: [
                PacketField.uint16(.socket, fromSocket),
                PacketField.string(.message, message, encoding: encoding)
            ]
        )
    }

    /// Reply to `getNewsList` (101). The entire feed travels in one
    /// `.message` field — the client splits on `\r` to surface
    /// individual posts.
    static func plainNewsReply(
        taskNumber: UInt32,
        feed: String,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 1,
            transactionID: 101,
            taskNumber: taskNumber,
            fields: [PacketField.string(.message, feed, encoding: encoding)]
        )
    }

    /// Push transID 102 (`kInfoNewPost`) for a fresh plain-news post.
    static func plainNewsPostPush(
        line: String,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 102,
            taskNumber: 0,
            fields: [PacketField.string(.message, line, encoding: encoding)]
        )
    }

    /// Reply with `errorID == 1` and no payload. Used by handlers that
    /// need to signal failure without a descriptive error message.
    static func errorReply(taskNumber: UInt32, transactionID: UInt16) -> Data {
        PacketCodec.encode(
            classID: 1,
            transactionID: transactionID,
            taskNumber: taskNumber,
            errorID: 1,
            fields: []
        )
    }

    /// Push transID 109 (`agreement`) with the server's banner text.
    /// `autoAgree` is always 0 in MVP — the client's UI confirms
    /// before sending the agree (121) back.
    static func agreementPush(text: String, encoding: String.Encoding) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 109,
            taskNumber: 0,
            fields: [
                PacketField.string(.message, text, encoding: encoding),
                PacketField.uint16(.autoAgree, 0)
            ]
        )
    }

    /// Reply to `getThreadedNewsBundles` (370). Each field is a single
    /// `newsBundleEntry` (object 323) describing one folder/category
    /// at the requested path.
    static func newsBundlesReply(
        taskNumber: UInt32,
        nodes: [BundleNode],
        encoding: String.Encoding
    ) -> Data {
        let fields = nodes.map { node -> PacketField in
            let count = UInt16(clamping: node.kind == .bundle ? node.children.count : node.posts.count)
            return NewsBundleEntryCodec.encode(
                name: node.name,
                kind: node.kind,
                itemCount: count,
                encoding: encoding
            )
        }
        return PacketCodec.encode(
            classID: 1,
            transactionID: 370,
            taskNumber: taskNumber,
            fields: fields
        )
    }

    /// Reply to `getThreadedNewsCategoryContents` (371). All threads in
    /// the category travel in a single `newsThreadList` (object 321) blob.
    static func newsCategoryReply(
        taskNumber: UInt32,
        posts: [NewsPost],
        encoding: String.Encoding
    ) -> Data {
        let now = Date()
        let entries = posts.enumerated().map { offset, post in
            NewsThreadListEntry(
                threadID: UInt16(offset + 1),
                parentID: 0,
                postedAt: now,
                title: post.title,
                author: post.author,
                body: post.body,
                mimeType: "text/plain"
            )
        }
        return PacketCodec.encode(
            classID: 1,
            transactionID: 371,
            taskNumber: taskNumber,
            fields: [NewsThreadListCodec.encode(entries, encoding: encoding)]
        )
    }

    /// Reply to `getNewsThreadBody` (400). Carries the post's title,
    /// author, MIME type ("text/plain" in this milestone), and body.
    static func newsThreadBodyReply(
        taskNumber: UInt32,
        post: NewsPost,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 1,
            transactionID: 400,
            taskNumber: taskNumber,
            fields: [
                PacketField.string(.newsTitle, post.title, encoding: encoding),
                PacketField.string(.newsAuthor, post.author, encoding: encoding),
                PacketField.string(.newsType, "text/plain", encoding: encoding),
                PacketField.string(.newsData, post.body, encoding: encoding)
            ]
        )
    }
}
