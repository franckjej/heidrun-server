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
    let files: FileVault
    let transfers: TransferRegistry
    let privateChats: PrivateChatRegistry
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
    /// Best-effort "host:port" for the remote peer, captured at
    /// connection time. Surfaced in the `getClientInfoText` (303)
    /// profile rendering.
    var remoteHost: String?
    /// Client-version (Hotline `versNum`) sent in the 107 login. `nil`
    /// before login.
    var clientVersion: UInt16?
    /// Wall-clock timestamp of the successful login. `nil` while still
    /// in handshake / pre-auth.
    var loginAt: Date?
    /// Last time we processed an inbound packet from this session. The
    /// idle-away supervisor reads this to decide when to flip the
    /// `.away` flag on the broadcast user record.
    var lastActivityAt = Date()
    /// Cached "did we already broadcast this session as away" flag.
    /// Used by `applyAwayState` to skip redundant broadcasts. Tracks
    /// the *combined* (idle || manual) state — see `applyAwayState`.
    var awayBroadcast: Bool = false
    /// `true` when the user explicitly ran `/away` and hasn't toggled
    /// it off. OR'd with the idle-derived state to produce the
    /// effective away bit broadcast to peers, so a manually-away
    /// session stays away even when the supervisor would otherwise
    /// clear the flag on the next active packet.
    var manuallyAway: Bool = false
    /// Inactivity threshold (seconds) the idle supervisor last passed
    /// to `reconcileAwayState`. Cached on the session so
    /// `applyAwayState` — called from both the supervisor and the
    /// `/away` chat command — has a single source of truth.
    /// Defaults to `.greatestFiniteMagnitude` so a session that hits
    /// `applyAwayState` before the supervisor ever runs (or with the
    /// supervisor disabled outright) reads as not-idle.
    var idleAwayThreshold: TimeInterval = .greatestFiniteMagnitude
    /// `true` when this session arrived on the TLS sibling listener
    /// (control port + 1 pair). Surfaced in the dispatch log + the
    /// 303 getClientInfoText profile so admins can confirm a user is
    /// connected end-to-end-encrypted.
    let isTLS: Bool
    /// Cached server banner bytes (loaded once at HeidrunServer.start)
    /// or `nil` when no banner is configured. Handed out unchanged
    /// on every 212 `downloadBanner` request.
    let bannerBytes: Data?
    /// Format hint sent in the 212 reply's `bannerType` field (152).
    let bannerKind: HeidrunCore.ServerBanner.Kind

    public init(
        registry: UserRegistry,
        news: NewsTree,
        accounts: AccountStore,
        files: FileVault,
        transfers: TransferRegistry,
        privateChats: PrivateChatRegistry,
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding,
        remoteHost: String? = nil,
        isTLS: Bool = false,
        bannerBytes: Data? = nil,
        bannerKind: HeidrunCore.ServerBanner.Kind = .jpeg,
        writer: @escaping @Sendable (Data) async throws -> Void,
        closer: @escaping @Sendable () async -> Void
    ) {
        self.registry = registry
        self.news = news
        self.accounts = accounts
        self.files = files
        self.transfers = transfers
        self.privateChats = privateChats
        self.configuration = configuration
        self.stringEncoding = stringEncoding
        self.remoteHost = remoteHost
        self.isTLS = isTLS
        self.bannerBytes = bannerBytes
        self.bannerKind = bannerKind
        self.writer = writer
        self.closer = closer
    }

    /// Public entrypoint used by `UserRegistry.broadcast`. Sessions
    /// don't write to other sessions' channels directly — the registry
    /// loops over every session and calls `send` here.
    public func send(_ packet: Data) async {
        try? await writer(packet)
    }

    /// Snapshot of everything `getClientInfoText` (303) needs about a
    /// session: identity bits the registry already has (nickname/icon/
    /// socket) plus per-session state only the actor knows (login,
    /// remote host, client version, login timestamp).
    public struct InfoSnapshot: Sendable {
        public let nickname: String
        public let icon: UInt16
        public let socketID: UInt16
        public let accountLogin: String?
        public let remoteHost: String?
        public let clientVersion: UInt16?
        public let loginAt: Date?
        public let isTLS: Bool
    }

    public func infoSnapshot() -> InfoSnapshot {
        InfoSnapshot(
            nickname: nickname,
            icon: icon,
            socketID: socketID,
            accountLogin: authenticatedAccount?.login,
            remoteHost: remoteHost,
            clientVersion: clientVersion,
            loginAt: loginAt,
            isTLS: isTLS
        )
    }

    /// Drop the underlying TCP connection. The session's `run` loop
    /// observes the close, runs its normal disconnect-cleanup path
    /// (unregister + broadcast `userLeft`), and returns. Used by the
    /// kick handler to disconnect a target by socketID.
    public func disconnectNow() async {
        await closer()
    }

    /// `true` when the authenticated account has every bit in `required`
    /// set. Guests with no account row (older deploys, or the guest row
    /// was deleted) report `false` for every check.
    func hasPrivilege(_ required: UserPrivileges) -> Bool {
        guard let account = authenticatedAccount else { return false }
        return (account.permissions & required.rawValue) == required.rawValue
    }

    /// Send a single chat line to JUST this session — no broadcast.
    /// Used by `/command` replies so the rest of the room never sees
    /// server-private output. The `*** ` prefix visually distinguishes
    /// server lines from user `<nick>: text` chat. ASCII-only so it
    /// can't be garbled by an encoding round-trip mismatch between
    /// the Linux server's `String.data(using: .macOSRoman)` and any
    /// particular client's decoder.
    func sendSystemReply(_ text: String) async {
        let line = "*** \(text)\r"
        try? await writer(PacketEncoder.chatPush(
            line: line, isAction: false, encoding: stringEncoding
        ))
    }

    /// Multi-line variant of `sendSystemReply`. Joins lines with `\r`
    /// so the client renders each on its own row inside one chatPush.
    func sendSystemReply(lines: [String]) async {
        let joined = lines.map { "*** \($0)" }.joined(separator: "\r") + "\r"
        try? await writer(PacketEncoder.chatPush(
            line: joined, isAction: false, encoding: stringEncoding
        ))
    }

    /// Idle-away supervisor callback. Stashes the operator-configured
    /// `threshold` on the session and delegates to `applyAwayState`,
    /// which is the shared reconciliation used by both the supervisor
    /// and the `/away` chat command.
    public func reconcileAwayState(threshold: TimeInterval) async {
        self.idleAwayThreshold = threshold
        await applyAwayState()
    }

    /// Compute the effective away state (idle OR manual) and, when it
    /// differs from what was last broadcast, push a `userChanged`
    /// (301) with the updated status. Shared between the idle
    /// supervisor and the `/away` chat command so the two can never
    /// disagree on the broadcast wire state.
    ///
    /// Skips pre-login sessions (`socketID == 0`) — those aren't in
    /// the registry yet and have nothing to broadcast.
    func applyAwayState() async {
        guard socketID != 0 else { return }
        let idleSeconds = Date().timeIntervalSince(lastActivityAt)
        let isIdle = idleSeconds >= idleAwayThreshold
        let isAway = isIdle || manuallyAway
        if isAway == awayBroadcast { return }

        let baseStatus = authenticatedAccount.initialHotStatus
        let awayBit: UInt16 = 1 << 0
        let newStatus: UInt16 = isAway ? (baseStatus | awayBit) : baseStatus
        guard let updated = await registry.updateMemberStatus(
            socketID: socketID, status: newStatus
        ) else {
            return
        }
        await registry.broadcast(
            PacketEncoder.userChangedPush(member: updated, encoding: stringEncoding),
            excluding: nil
        )
        awayBroadcast = isAway
        // Bumped to INFO: transitions are infrequent (one per session
        // per ~10 min in typical deployments) but operationally
        // interesting — they're the visible signal that an idle
        // supervisor flap or a /away toggle happened.
        serverLogger.info("away reconcile", metadata: [
            "socketID": "\(socketID)",
            "nickname": "\(nickname)",
            "isAway": "\(isAway)",
            "isIdle": "\(isIdle)",
            "manuallyAway": "\(manuallyAway)",
            "idleSeconds": "\(Int(idleSeconds))"
        ])
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
            // Drop the session from every private chat it joined so
            // remaining members' rosters stay accurate.
            let evictions = await privateChats.evictFromAll(socket: leftSocket)
            for (chatID, remaining) in evictions {
                let push = PacketEncoder.privateChatLeftPush(
                    chatReference: ChatID(rawValue: chatID).data,
                    socket: leftSocket
                )
                for socket in remaining {
                    if let session = await registry.lookup(socketID: socket) {
                        await session.send(push)
                    }
                }
            }
            await registry.unregister(socketID: leftSocket)
            await registry.broadcast(PacketEncoder.userLeftPush(socketID: leftSocket))
            serverLogger.info("user disconnected", metadata: [
                "socketID": "\(leftSocket)",
                "nickname": "\(nickname)",
                "remoteHost": "\(remoteHost ?? "—")",
                "tls": "\(isTLS)"
            ])
        }
    }

    /// Returns `true` if the caller should keep dispatching frames,
    /// `false` to break out of the read loop (e.g. on a client-initiated
    /// disconnect transaction).
    private func dispatch(header: PacketHeader, fields: [PacketField]) async -> Bool {
        // Bump activity for the idle-away supervisor — but ONLY for
        // user-driven transactions. Skip transID 500 (185-style ping)
        // because clients send those automatically every ~60s as
        // keepalive; counting them as activity prevents the supervisor
        // from ever seeing a "truly idle" user. With a 600s default
        // threshold and 60s client pings, idle-away would otherwise
        // never fire in practice.
        //
        // Pre-login frames (socketID == 0) still bump so a slow
        // handshake doesn't immediately count as idle once the session
        // finally registers — the pre-login window is bounded by the
        // client's handshake timeout, not the idle threshold.
        if header.transactionID != 500 {
            lastActivityAt = Date()
        }
        // `socketID == 0` means we haven't called `registry.register`
        // yet — i.e. the session is still pre-login. Mask the
        // placeholder nickname + socket fields so the log doesn't
        // look like a real "guest" account; on every dispatch after
        // `handleLogin` runs, both fields show their assigned values.
        let isPreLogin = (socketID == 0)
        serverLogger.debug("dispatch", metadata: [
            "transID": "\(header.transactionID)",
            "taskNumber": "\(header.taskNumber)",
            "socketID": isPreLogin ? "—" : "\(socketID)",
            "nickname": isPreLogin ? "—" : "\(nickname)",
            "remoteHost": "\(remoteHost ?? "—")",
            "tls": "\(isTLS)",
            "fieldCount": "\(fields.count)"
        ])
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
        case 303:
            await handleGetClientInfo(header: header, fields: fields)
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
        case 381:
            await handleCreateNewsBundle(header: header, fields: fields)
            return true
        case 382:
            await handleCreateNewsCategory(header: header, fields: fields)
            return true
        case 110:
            await handleKick(header: header, fields: fields)
            return true
        case 350:
            await handleCreateLogin(header: header, fields: fields)
            return true
        case 351:
            await handleDeleteLogin(header: header, fields: fields)
            return true
        case 352:
            await handleOpenLogin(header: header, fields: fields)
            return true
        case 353:
            await handleModifyLogin(header: header, fields: fields)
            return true
        case 200:
            await handleListFiles(header: header, fields: fields)
            return true
        case 202:
            await handleDownloadFile(header: header, fields: fields)
            return true
        case 203:
            await handleUploadFile(header: header, fields: fields)
            return true
        case 204:
            await handleDeleteEntry(header: header, fields: fields)
            return true
        case 205:
            await handleCreateFolder(header: header, fields: fields)
            return true
        case 206:
            await handleFileInfo(header: header, fields: fields)
            return true
        case 207:
            await handleSetFileInfo(header: header, fields: fields)
            return true
        case 208:
            await handleMoveEntry(header: header, fields: fields)
            return true
        case 209:
            await handleMakeAlias(header: header, fields: fields)
            return true
        case 210:
            await handleDownloadFolder(header: header, fields: fields)
            return true
        case 213:
            await handleUploadFolder(header: header, fields: fields)
            return true
        case 212:
            await handleDownloadBanner(header: header)
            return true
        case 304:
            await handleSetClientUserInfo(header: header, fields: fields)
            return true
        case 355:
            await handleBroadcast(header: header, fields: fields)
            return true
        case 380:
            await handleDeleteNewsBundle(header: header, fields: fields)
            return true
        case 411:
            await handleDeleteNewsThread(header: header, fields: fields)
            return true
        case 214:
            await handleDeleteTransfer(header: header, fields: fields)
            return true
        case 112:
            await handleCreatePrivateChat(header: header, fields: fields)
            return true
        case 113:
            await handleInviteToPrivateChat(header: header, fields: fields)
            return true
        case 114:
            await handleRejectPrivateChat(header: header, fields: fields)
            return true
        case 115:
            await handleJoinPrivateChat(header: header, fields: fields)
            return true
        case 116:
            await handleLeavePrivateChat(header: header, fields: fields)
            return true
        case 120:
            await handleSetPrivateChatSubject(header: header, fields: fields)
            return true
        case 500:
            // 185-style ping. Client sends as no-reply; nothing for
            // the server to do beyond not falling through silently.
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
        self.clientVersion = fields.uint16(.clientVersion)
        self.loginAt = Date()

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
        } else {
            // Empty login = guest. Attach the seeded `guest` row so the
            // session picks up the operator-configured guest permission
            // set (and any later modifyLogin adjustments). Falls back
            // to `nil` when the row is missing — deployments that
            // explicitly deleted it to disable anonymous access keep
            // the old "no privileges" behaviour.
            self.authenticatedAccount = try? await accounts.get(login: Account.guestLogin)
        }

        self.nickname = nick
        self.icon = iconValue

        let initialStatus = authenticatedAccount.initialHotStatus
        let assigned = await registry.register(
            session: self,
            nickname: nick,
            icon: iconValue,
            status: initialStatus
        )
        self.socketID = assigned
        serverLogger.info("user logged in", metadata: [
            "socketID": "\(assigned)",
            "nickname": "\(nick)",
            "login": "\(login.isEmpty ? "guest" : login)",
            "remoteHost": "\(remoteHost ?? "—")",
            "tls": "\(isTLS)",
            "isAdmin": "\(authenticatedAccount?.isAdmin ?? false)",
            "status": "0x\(String(initialStatus, radix: 16))",
            "permissions": "0x\(String(authenticatedAccount?.permissions ?? 0, radix: 16))"
        ])

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
            status: initialStatus
        )
        await registry.broadcast(
            PacketEncoder.userChangedPush(member: member, encoding: stringEncoding),
            excluding: assigned
        )

        // Real Hotline servers push the agreement (transID 109) right
        // after the login reply. Skipped when no agreement is
        // configured, or when the authenticated account holds the
        // `.dontShowAgreement` privilege — admin-style accounts opt
        // out so they don't see the welcome banner every time they
        // reconnect. Mirrors HeidrunTestServer/Connection.swift's
        // gate, which has lived in the test server since the protocol
        // package's first release.
        if let text = configuration.agreement, !hasPrivilege(.dontShowAgreement) {
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

    /// Handle `getClientInfoText` (303): look up the addressed user
    /// and reply with the standard envelope plus a column-aligned
    /// "profile" info text — the format mature Hotline servers send,
    /// matching what `HeidrunTestServer` renders.
    ///
    /// Gated on the `.getUserInfo` privilege: the profile leaks the
    /// target's remote IP, login timestamp, and client version, so
    /// guests (and any other account missing the bit) get an
    /// errorID=1 reply instead. Operators grant individual accounts
    /// the bit via `modifyLogin` (353) when they need admins/mods to
    /// see peer details.
    private func handleGetClientInfo(header: PacketHeader, fields: [PacketField]) async {
        guard hasPrivilege(.getUserInfo) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 303
            ))
            return
        }
        let target = fields.uint16(.socket) ?? 0
        let members = await registry.snapshot()
        guard let member = members.first(where: { $0.socketID == target }) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 303
            ))
            return
        }
        let targetSession = await registry.lookup(socketID: target)
        let snapshot = await targetSession?.infoSnapshot()
        let infoText = Self.renderUserInfoProfile(member: member, snapshot: snapshot)
        let login = snapshot?.accountLogin ?? ""
        try? await writer(PacketEncoder.userInfoReply(
            taskNumber: header.taskNumber,
            socket: member.socketID,
            nickname: member.nickname,
            icon: member.icon,
            status: member.status,
            login: login,
            infoText: infoText,
            encoding: stringEncoding
        ))
    }

    /// Column-aligned profile dump for the `getClientInfoText` reply —
    /// one row per field, `\r` line breaks (Hotline's wire newline),
    /// padded so colons line up.
    static func renderUserInfoProfile(
        member: UserRegistry.Member,
        snapshot: InfoSnapshot?
    ) -> String {
        let labelWidth = "login tm".count
        func row(_ label: String, _ value: String) -> String {
            let padded = String(repeating: " ", count: max(0, labelWidth - label.count)) + label
            return "\(padded): \(value)"
        }

        let host    = snapshot?.remoteHost ?? "—"
        let login   = snapshot?.accountLogin ?? "—"
        let version = snapshot?.clientVersion.map { "\($0) compatible" } ?? "—"
        let loginTm = snapshot?.loginAt.map(Self.formatLoginTime) ?? "—"
        let status  = UserStatus(rawValue: member.status)

        let tls = (snapshot?.isTLS ?? false) ? "yes" : "no"

        let lines: [String] = [
            row("name", member.nickname),
            row("login", login),
            row("host", host),
            row("version", version),
            row("uid", "\(member.socketID)"),
            row("color", "\(status.color)"),
            row("icon", "\(member.icon)"),
            row("login tm", loginTm),
            row("tls", tls),
            "--------------------------------",
            " - Downloads -",
            " - Uploads -"
        ]
        return lines.joined(separator: "\r")
    }

    /// Format a login timestamp the way Hotline servers traditionally
    /// rendered it — `h:mm:ssa zzz MMM d`. Used by the
    /// `getClientInfoText` (303) profile and the `/whoami` chat
    /// command; lifted to `internal` so extension files can share it.
    static func formatLoginTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm:ssa zzz MMM d"
        return formatter.string(from: date)
    }

    private func handleChat(header: PacketHeader, fields: [PacketField]) async {
        guard let body = fields.string(.message, encoding: stringEncoding) else {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 105
            ))
            return
        }
        // Slash-commands are intercepted before the broadcast path —
        // never echoed as chat to other users. Unknown / well-formed
        // / both ack with an emptyReply so the client's task tracker
        // doesn't time out.
        if await handleChatCommandIfPresent(body: body, header: header) {
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
