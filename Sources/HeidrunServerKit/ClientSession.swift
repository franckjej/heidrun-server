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
    let configuration: ServerConfiguration
    let stringEncoding: String.Encoding
    let writer: @Sendable (Data) async throws -> Void
    let closer: @Sendable () async -> Void

    var socketID: UInt16 = 0
    var nickname: String = "guest"
    var icon: UInt16 = 0

    public init(
        registry: UserRegistry,
        news: NewsTree,
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding,
        writer: @escaping @Sendable (Data) async throws -> Void,
        closer: @escaping @Sendable () async -> Void
    ) {
        self.registry = registry
        self.news = news
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
        default:
            return true
        }
    }

    private func handleLogin(header: PacketHeader, fields: [PacketField]) async {
        let nick = fields.string(.nickname, encoding: stringEncoding) ?? "guest"
        let iconValue = fields.uint16(.icon) ?? 0
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

        // Tell every other session about the new arrival so their user
        // lists refresh.
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
