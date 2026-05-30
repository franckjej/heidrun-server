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
                    nickname: member.nickname,
                    emoji: member.emoji
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
                PacketField.string(.nickname, member.nickname, encoding: encoding),
                PacketField.string(.userEmoji, member.emoji ?? "", encoding: .utf8)
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

    /// Push transID 355 (`kInfoServerMsg`) — server-wide broadcast.
    /// Sent to every connected session except the originator (whose
    /// own request gets an empty 355 reply matched by taskNumber).
    static func serverBroadcastPush(
        message: String,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 355,
            taskNumber: 0,
            fields: [PacketField.string(.message, message, encoding: encoding)]
        )
    }

    /// Push transID 113 (`privateChatInvitation`) — sent to the
    /// addressed target when somebody creates a private chat with
    /// them or invites them to an existing room.
    static func privateChatInvitePush(
        chatReference: Data,
        fromSocket: UInt16,
        message: String,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 113,
            taskNumber: 0,
            fields: [
                PacketField(key: .chatReference, data: chatReference),
                PacketField.uint16(.socket, fromSocket),
                PacketField.string(.message, message, encoding: encoding)
            ]
        )
    }

    /// Push transID 117 (`privateChatJoined`) — used twice on join:
    /// once per existing member to hydrate the joiner's roster, then
    /// once per existing member to announce the joiner.
    static func privateChatJoinedPush(
        chatReference: Data,
        member: UserRegistry.Member,
        encoding: String.Encoding
    ) -> Data {
        let user = User(
            socket: member.socketID,
            icon: member.icon,
            status: UserStatus(rawValue: member.status),
            privileges: [],
            nickname: member.nickname
        )
        return PacketCodec.encode(
            classID: 0,
            transactionID: 117,
            taskNumber: 0,
            fields: [
                PacketField(key: .chatReference, data: chatReference),
                UserListEntryCodec.encode(user, encoding: encoding)
            ]
        )
    }

    /// Push transID 118 (`privateChatLeft`) — sent to the remaining
    /// members of the room when somebody leaves or disconnects.
    static func privateChatLeftPush(
        chatReference: Data,
        socket: UInt16
    ) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 118,
            taskNumber: 0,
            fields: [
                PacketField(key: .chatReference, data: chatReference),
                PacketField.uint16(.socket, socket)
            ]
        )
    }

    /// Push transID 119 (`privateChatChangedSubject`) — broadcast a
    /// new subject to every other member of the addressed room.
    static func privateChatSubjectPush(
        chatReference: Data,
        subject: String,
        encoding: String.Encoding
    ) -> Data {
        PacketCodec.encode(
            classID: 0,
            transactionID: 119,
            taskNumber: 0,
            fields: [
                PacketField(key: .chatReference, data: chatReference),
                PacketField.string(.chatSubject, subject, encoding: encoding)
            ]
        )
    }

    /// Push transID 119 (`NotifyChatSubject`) for the **public/main**
    /// chat. Same wire shape as `privateChatSubjectPush` but with a zero
    /// Chat ID (`0x00000000`), which the client maps to the public chat's
    /// topic. Sent on login (when a topic is set) and on every `/topic`.
    static func publicChatSubjectPush(
        subject: String,
        encoding: String.Encoding
    ) -> Data {
        privateChatSubjectPush(
            chatReference: Data([0, 0, 0, 0]),
            subject: subject,
            encoding: encoding
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
    /// Reply to `getClientInfoText` (303). Carries the target's
    /// nickname, icon, status, optional account login, and a free-form
    /// info-text blob the client displays verbatim.
    static func userInfoReply(
        taskNumber: UInt32,
        socket: UInt16,
        nickname: String,
        icon: UInt16,
        status: UInt16,
        login: String,
        infoText: String,
        encoding: String.Encoding
    ) -> Data {
        var fields: [PacketField] = [
            PacketField.uint16(.socket, socket),
            PacketField.uint16(.icon, icon),
            PacketField.uint16(.status, status),
            PacketField.string(.nickname, nickname, encoding: encoding)
        ]
        if !login.isEmpty {
            fields.append(PacketField.string(.login, login, encoding: encoding))
        }
        if !infoText.isEmpty {
            fields.append(PacketField.string(.message, infoText, encoding: encoding))
        }
        return PacketCodec.encode(
            classID: 1,
            transactionID: 303,
            taskNumber: taskNumber,
            fields: fields
        )
    }

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

    /// Reply to `openLogin` (352). Carries the account's nickname and
    /// 8-byte privileges blob — password material never leaves the
    /// server even for admin reads. Real Hotline servers send back the
    /// XOR-obfuscated password too; we deliberately omit it because
    /// HeidrunServer only stores PBKDF2 hashes and can't reverse them.
    static func openLoginReply(
        taskNumber: UInt32,
        account: Account,
        encoding: String.Encoding
    ) -> Data {
        var permissionBytes = [UInt8](repeating: 0, count: 8)
        for index in 0..<8 {
            permissionBytes[index] = UInt8(
                truncatingIfNeeded: account.permissions >> (index * 8)
            )
        }
        return PacketCodec.encode(
            classID: 1,
            transactionID: 352,
            taskNumber: taskNumber,
            fields: [
                PacketField.string(.nickname, account.nickname, encoding: encoding),
                PacketField(key: .privileges, data: Data(permissionBytes))
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
                parentID: post.parentID,
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

    /// Reply to `getFileList` (200). Each field is a `fileListEntry`
    /// object describing one entry at the requested path.
    static func fileListReply(
        taskNumber: UInt32,
        entries: [FileVault.Entry],
        encoding: String.Encoding
    ) -> Data {
        let fields = entries.map { entry in
            FileListEntryCodec.encode(
                RemoteFile(
                    name: entry.name,
                    type: entry.type,
                    creator: entry.creator,
                    size: entry.size,
                    itemCount: entry.itemCount
                ),
                encoding: encoding
            )
        }
        return PacketCodec.encode(
            classID: 1,
            transactionID: 200,
            taskNumber: taskNumber,
            fields: fields
        )
    }

    /// Reply to `uploadFile` (203). Carries just the server-allocated
    /// transferID — the client follows up with an HTXF connection.
    static func uploadFileReply(
        taskNumber: UInt32,
        transferID: UInt32
    ) -> Data {
        PacketCodec.encode(
            classID: 1,
            transactionID: 203,
            taskNumber: taskNumber,
            fields: [PacketField.uint32(.transferID, transferID)]
        )
    }

    /// Reply to `downloadFile` (202). Carries the server-allocated
    /// transferID + the byte count the HTXF channel will stream.
    static func downloadFileReply(
        taskNumber: UInt32,
        transferID: UInt32,
        transferSize: UInt32
    ) -> Data {
        PacketCodec.encode(
            classID: 1,
            transactionID: 202,
            taskNumber: taskNumber,
            fields: [
                PacketField.uint32(.transferID, transferID),
                PacketField.uint32(.transferSize, transferSize)
            ]
        )
    }

    /// Reply to `downloadBanner` (212). Same transferID + size
    /// shape as a file download, plus an optional `bannerType` (152)
    /// format hint so the client knows whether the bytes will be
    /// JPEG / GIF / BMP / PICT / a URL.
    static func bannerReply(
        taskNumber: UInt32,
        transferID: UInt32,
        transferSize: UInt32,
        bannerKind: HeidrunCore.ServerBanner.Kind
    ) -> Data {
        PacketCodec.encode(
            classID: 1,
            transactionID: 212,
            taskNumber: taskNumber,
            fields: [
                PacketField.uint32(.transferID, transferID),
                PacketField.uint32(.transferSize, transferSize),
                PacketField.uint16(.bannerType, bannerKind.rawValue)
            ]
        )
    }

    /// Reply to `getFileInfo` (206). Carries the file's name, type,
    /// creator, size, creation/modification timestamps, and optional
    /// comment.
    static func fileInfoReply(
        taskNumber: UInt32,
        info: FileVault.Info,
        encoding: String.Encoding
    ) -> Data {
        var out: [PacketField] = [
            PacketField.string(.fileName, info.entry.name, encoding: encoding),
            PacketField(key: .longFileType, data: LongFourCC.encode(info.entry.type)),
            PacketField(key: .longFileCreator, data: LongFourCC.encode(info.entry.creator)),
            PacketField.uint32(.fileSize, info.entry.size),
            HotlineDateField.encode(info.created, key: .fileCreationDate),
            HotlineDateField.encode(info.modified, key: .fileModificationDate)
        ]
        if !info.comment.isEmpty {
            out.append(PacketField.string(.fileComment, info.comment, encoding: encoding))
        }
        return PacketCodec.encode(
            classID: 1,
            transactionID: 206,
            taskNumber: taskNumber,
            fields: out
        )
    }
}
