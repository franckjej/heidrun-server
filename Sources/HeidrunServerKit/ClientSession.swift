import Foundation
import HeidrunCore

/// One-per-connection actor. Owns the inbound `ByteStream`, the
/// outbound writer closure, the assigned `socketID` (after login), and
/// the user's display profile. The actor isolates all mutable state
/// behind `await` boundaries so the broadcast fan-out from
/// `UserRegistry` can safely call `send(_:)` from any task.
public actor ClientSession {
    let registry: UserRegistry
    let news: NewsTree
    let accounts: AccountStore
    let configuration: ServerConfiguration
    let stringEncoding: String.Encoding
    let writer: @Sendable (Data) async throws -> Void
    let closer: @Sendable () async -> Void

    var socketID: UInt16 = 0
    var nickname: String = "guest"
    var icon: UInt16 = 0
    /// Account row that authenticated the current session, or `nil`
    /// for guest connections (empty login). Used by privilege checks.
    var authenticatedAccount: Account?

    public init(
        registry: UserRegistry,
        news: NewsTree,
        accounts: AccountStore,
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding,
        writer: @escaping @Sendable (Data) async throws -> Void,
        closer: @escaping @Sendable () async -> Void
    ) {
        self.registry = registry
        self.news = news
        self.accounts = accounts
        self.configuration = configuration
        self.stringEncoding = stringEncoding
        self.writer = writer
        self.closer = closer
    }

    /// Public entrypoint used by `UserRegistry.broadcast`. Sessions
    /// don't write to other sessions' channels directly — the registry
    /// loops over every session and calls `send` here.
    public func send(_ packet: Data) async {
        try? await writer(packet)
    }

    /// Drop the underlying TCP connection. The session's `run` loop
    /// observes the close, runs its normal disconnect-cleanup path
    /// (unregister + broadcast `userLeft`), and returns. Used by the
    /// kick handler to disconnect a target by socketID.
    public func disconnectNow() async {
        await closer()
    }

    /// Drive the connection from raw inbound bytes through handshake,
    /// frame loop, and clean disconnect. Returns when the client
    /// disconnects (gracefully or not).
    public func run<Source: AsyncSequence & Sendable>(_ inbound: Source) async
    where Source.Element == Data {
        var stream = ByteStream(source: inbound)

        // Handshake. A bad handshake closes the connection without
        // entering the framing loop or registering a user.
        do {
            let magic = try await stream.receiveExactly(12)
            let ack = try Handshake.parse(magic)
            try await writer(ack)
        } catch {
            await closer()
            return
        }

        // Framing loop. Reads PacketHeader (20 bytes) + body
        // (header.dataLength bytes) and dispatches.
        while true {
            do {
                let headerBytes = try await stream.receiveExactly(PacketHeader.byteCount)
                guard let header = PacketHeader(decoding: headerBytes) else {
                    await closer()
                    break
                }
                let body: Data
                if header.dataLength > 0 {
                    body = try await stream.receiveExactly(Int(header.dataLength))
                } else {
                    body = Data()
                }
                let fields = PacketCodec.decodeBody(body)
                let keepGoing = await dispatch(header: header, fields: fields)
                if !keepGoing { break }
            } catch {
                break
            }
        }

        // Clean disconnect: unregister and tell the rest of the roster.
        // No-op if the session never made it past login (socketID == 0).
        if socketID != 0 {
            let leftSocket = socketID
            await registry.unregister(socketID: leftSocket)
            await registry.broadcast(PacketEncoder.userLeftPush(socketID: leftSocket))
        }
    }

    /// Returns `true` if the caller should keep dispatching frames,
    /// `false` to break out of the read loop (e.g. on a client-initiated
    /// disconnect transaction).
    private func dispatch(header: PacketHeader, fields: [PacketField]) async -> Bool {
        switch header.transactionID {
        case 107:
            await handleLogin(header: header, fields: fields)
            return true
        case 121:
            return true                                  // agreement ack — no reply
        case 109:
            return false                                 // client-initiated disconnect
        case 300:
            await handleUserList(header: header)
            return true
        case 105:
            await handleChat(header: header, fields: fields)
            return true
        case 108:
            await handlePrivateMessage(header: header, fields: fields)
            return true
        case 101:
            await handleFetchPlainNews(header: header)
            return true
        case 103:
            await handlePostPlainNews(header: header, fields: fields)
            return true
        case 370:
            await handleGetNewsBundles(header: header, fields: fields)
            return true
        case 371:
            await handleGetNewsCategory(header: header, fields: fields)
            return true
        case 400:
            await handleGetNewsThread(header: header, fields: fields)
            return true
        case 410:
            await handlePostNewsThread(header: header, fields: fields)
            return true
        case 110:
            await handleKick(header: header, fields: fields)
            return true
        default:
            return true
        }
    }

    private func handleLogin(header: PacketHeader, fields: [PacketField]) async {
        let nick = fields.string(.nickname, encoding: stringEncoding) ?? "guest"
        let iconValue = fields.uint16(.icon) ?? 0
        let login = Self.obfuscatedString(.login, from: fields, encoding: stringEncoding) ?? ""
        let password = Self.obfuscatedString(.password, from: fields, encoding: stringEncoding) ?? ""

        // Authenticate when a login was supplied. Empty login = guest.
        // A non-empty login that doesn't match an account, or a wrong
        // password, fails with errorID=1 and no user-list registration.
        if !login.isEmpty {
            let verified = try? await accounts.verifyCredentials(login: login, password: password)
            guard let account = verified else {
                try? await writer(PacketEncoder.errorReply(
                    taskNumber: header.taskNumber,
                    transactionID: 107
                ))
                return
            }
            self.authenticatedAccount = account
        }

        self.nickname = nick
        self.icon = iconValue

        let assigned = await registry.register(session: self, nickname: nick, icon: iconValue)
        self.socketID = assigned

        let reply = PacketEncoder.loginReply(
            taskNumber: header.taskNumber,
            advertisedVersion: configuration.advertisedVersion,
            socketID: assigned,
            serverName: configuration.serverName,
            encoding: stringEncoding
        )
        try? await writer(reply)

        let member = UserRegistry.Member(
            socketID: assigned,
            nickname: nick,
            icon: iconValue,
            status: 0
        )
        await registry.broadcast(
            PacketEncoder.userChangedPush(member: member, encoding: stringEncoding),
            excluding: assigned
        )

        if let text = configuration.agreement {
            try? await writer(PacketEncoder.agreementPush(text: text, encoding: stringEncoding))
        }
    }

    /// Read an obfuscated string field (login / password): each byte is
    /// XOR'd with `0xFF` on the wire; decoding inverts that.
    nonisolated static func obfuscatedString(
        _ key: HotlineObjectKey,
        from fields: [PacketField],
        encoding: String.Encoding
    ) -> String? {
        guard let field = fields.first(key) else { return nil }
        var bytes = Array(field.data)
        for index in bytes.indices {
            bytes[index] ^= 0xFF
        }
        return String(data: Data(bytes), encoding: encoding)
    }

    private func handleUserList(header: PacketHeader) async {
        let members = await registry.snapshot()
        let reply = PacketEncoder.userListReply(
            taskNumber: header.taskNumber,
            members: members,
            encoding: stringEncoding
        )
        try? await writer(reply)
    }

    private func handleChat(header: PacketHeader, fields: [PacketField]) async {
        guard let body = fields.string(.message, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 105
            ))
            return
        }
        let isAction = (fields.uint16(.parameter) ?? 0) != 0
        let line = " \(nickname): \(body)\r"
        let push = PacketEncoder.chatPush(line: line, isAction: isAction, encoding: stringEncoding)
        await registry.broadcast(push)
        try? await writer(PacketEncoder.emptyReply(
            taskNumber: header.taskNumber,
            transactionID: 105
        ))
    }
}
