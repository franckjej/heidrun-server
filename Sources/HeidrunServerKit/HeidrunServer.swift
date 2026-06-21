import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import HeidrunCore

/// Top-level server. `start()` binds the control TCP listener on the
/// configured port **and** the HTXF transfer listener on `port + 1`,
/// then returns the control port. `stop()` tears both down.
public actor HeidrunServer {
    private let configuration: ServerConfiguration
    private let stringEncoding: String.Encoding
    private let registry: UserRegistry
    private let news: NewsTree
    private let chatSubject: ChatSubjectStore
    private let transfers: TransferRegistry
    private let privateChats: PrivateChatRegistry
    private var accounts: AccountStore?
    private var group: (any EventLoopGroup)?
    private var controlChannel: (any Channel)?
    private var transferChannel: (any Channel)?
    private var tlsControlChannel: (any Channel)?
    private var tlsTransferChannel: (any Channel)?
    private var trackerAnnouncer: TrackerAnnouncer?
    private var idleAwaySupervisor: Task<Void, Never>?
    /// Live accepted connections, drained on `stop()` before the event-loop
    /// group shuts down so per-connection session tasks never schedule on a
    /// dead loop.
    private let connections = ConnectionTracker()

    /// Number of live accepted connections. Test/diagnostic aid.
    var liveConnectionCount: Int { connections.count }

    public init(
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding = .macOSRoman
    ) {
        self.configuration = configuration
        self.stringEncoding = stringEncoding
        self.registry = UserRegistry()
        self.news = NewsTree(
            seed: configuration.newsSeed ?? NewsTree.Seed(),
            persistencePath: configuration.newsStatePath
        )
        self.chatSubject = ChatSubjectStore(
            seed: configuration.chatSubject,
            persistencePath: configuration.chatSubjectStatePath
        )
        self.transfers = TransferRegistry()
        self.privateChats = PrivateChatRegistry()
    }

    /// Bind the control listener AND the transfer listener (port + 1).
    /// The `childChannelInitializer` installs the inbound-byte handler
    /// and spawns the per-session async task synchronously on the
    /// child's event loop, before any reads happen — otherwise the
    /// client's 12-byte handshake races our handler installation and
    /// the session reads zero bytes forever. (See
    /// `feedback_nio_child_channel_init` for the war story.)
    public func start() async throws -> UInt16 {
        // One-shot news wipe: when an operator sets HEIDRUN_NEWS_RESET
        // (or news_reset in TOML), clear the chosen store(s) and
        // re-persist the empty snapshot before serving. Operator-driven
        // like resetAdminPermissions — flip it on, deploy once, flip it
        // off so subsequent restarts don't wipe accumulated news.
        if let scope = configuration.newsReset {
            await news.reset(scope)
            serverLogger.info("news reset on startup (HEIDRUN_NEWS_RESET)", metadata: [
                "scope": "\(scope.rawValue)"
            ])
        }
        let accountStore = try AccountStore(
            path: configuration.accountStorePath,
            passwordRounds: configuration.passwordRounds
        )
        // File metadata persistence rides along the same SQLite file
        // as the accounts DB when one is configured; otherwise it's
        // in-memory and wipes alongside the account store.
        let fileMetadataStore = try FileMetadataStore(path: configuration.accountStorePath)
        // Audit log: presence, transfers, auth, and admin events in their
        // own SQLite file (separate from accounts; in-memory when no path).
        // nil when the master switch is off — disables all recording and
        // makes /usershistory + /audit report it's disabled.
        let auditLog = configuration.auditLogEnabled
            ? try AuditLog(path: configuration.auditDBPath, retentionDays: configuration.auditRetentionDays)
            : nil
        let fileVault = try FileVault(
            rootPath: configuration.filesRootPath,
            metadata: fileMetadataStore
        )
        if let bootstrap = configuration.bootstrapAdmin {
            // Seed every defined privilege so the bootstrap admin can
            // actually administer. The HeidrunServer-side
            // `AccountPrivilege` enum only models the bits we currently
            // enforce server-side; the client UI gates many more
            // buttons on the full `UserPrivileges` set, and missing
            // bits look like "you don't have permission" in the client.
            let seeded = try await accountStore.bootstrapIfEmpty(
                login: bootstrap.login,
                password: bootstrap.password,
                nickname: bootstrap.nickname,
                permissions: UserPrivileges.all.rawValue
            )
            if seeded {
                serverLogger.info("bootstrap admin seeded", metadata: [
                    "login": "\(bootstrap.login)",
                    "permissions": "0x\(String(UserPrivileges.all.rawValue, radix: 16))"
                ])
            } else {
                // Pre-existing row keeps its stored permissions — operators
                // re-deploying on top of an older DB may have a stale admin
                // missing privilege bits added after their first launch.
                serverLogger.info("bootstrap admin skipped (accounts table not empty)", metadata: [
                    "login": "\(bootstrap.login)"
                ])
                // One-shot upgrade hook: when an operator sets
                // HEIDRUN_RESET_ADMIN_PERMISSIONS=1 (or
                // reset_admin_permissions=true in TOML), force the
                // bootstrap admin's permissions to UserPrivileges.all.
                // Use to recover from the pre-`8a78eb1` (May 22 2026)
                // seed that only included 5 enforcement bits. Idempotent
                // but operator-driven: flip the flag on, deploy once to
                // refresh the row, flip it off again so subsequent
                // restarts don't clobber operator-tightened permissions.
                if configuration.resetAdminPermissions {
                    let updated = try await accountStore.update(
                        login: bootstrap.login,
                        nickname: nil,
                        iconID: nil,
                        permissions: UserPrivileges.all.rawValue,
                        newPassword: nil
                    )
                    if updated != nil {
                        serverLogger.info("bootstrap admin permissions reset (HEIDRUN_RESET_ADMIN_PERMISSIONS)", metadata: [
                            "login": "\(bootstrap.login)",
                            "permissions": "0x\(String(UserPrivileges.all.rawValue, radix: 16))"
                        ])
                    } else {
                        serverLogger.warning("HEIDRUN_RESET_ADMIN_PERMISSIONS set but no row matches the configured bootstrap admin login", metadata: [
                            "login": "\(bootstrap.login)"
                        ])
                    }
                }
            }
        }
        // Always make sure a `guest` row exists so anonymous logins
        // (empty login on the wire) pick up operator-configurable
        // permissions, and the row surfaces in the admin UI for
        // tightening or loosening via modifyLogin (353). Idempotent —
        // pre-existing rows keep their stored permissions.
        let guestSeeded = try await accountStore.ensureExists(
            login: Account.guestLogin,
            password: "",
            nickname: "Guest",
            permissions: Account.guestDefaultPermissions
        )
        if guestSeeded {
            serverLogger.info("guest account seeded", metadata: [
                "login": "\(Account.guestLogin)",
                "permissions": "0x\(String(Account.guestDefaultPermissions, radix: 16))"
            ])
        }
        self.accounts = accountStore

        // Load the server banner once at startup, if configured. Same
        // workflow as the TLS cert: bytes live in memory; updating
        // the file requires a restart. A missing path or unreadable
        // file logs a warning + disables the banner (212 will reply
        // with an error, which the client surfaces as `nil`).
        let bannerBytes: Data?
        if let bannerPath = configuration.bannerPath, !bannerPath.isEmpty {
            do {
                let loaded = try Data(contentsOf: URL(fileURLWithPath: bannerPath))
                bannerBytes = loaded
                serverLogger.info("loaded server banner", metadata: [
                    "path": "\(bannerPath)",
                    "size": "\(loaded.count)",
                    "kind": "\(configuration.bannerKind.rawValue)"
                ])
                // Sanity check: warn if the configured banner_kind
                // doesn't match the file's magic bytes. JPEG / GIF /
                // BMP have well-known signatures; PICT has a 512-byte
                // header before the magic so we skip that case;
                // URL-mode treats the bytes as a UTF-8 link so a
                // magic-byte check is meaningless. A mismatch doesn't
                // disable the banner — modern clients usually sniff
                // the format themselves — but the WARNING gives the
                // operator a clear pointer to a config typo.
                if let detected = Self.detectedBannerFormat(loaded),
                   detected != configuration.bannerKind {
                    serverLogger.warning("banner kind mismatch", metadata: [
                        "configured": "\(configuration.bannerKind.rawValue)",
                        "detected": "\(detected.rawValue)",
                        "hint": "update HEIDRUN_BANNER_KIND / banner_kind to match the file"
                    ])
                }
            } catch {
                serverLogger.warning("failed to load banner; 212 requests will fail", metadata: [
                    "path": "\(bannerPath)",
                    "error": "\(error)"
                ])
                bannerBytes = nil
            }
        } else {
            bannerBytes = nil
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = eventLoopGroup

        let registryCopy = self.registry
        let newsCopy = self.news
        let chatSubjectCopy = self.chatSubject
        let transfersCopy = self.transfers
        let privateChatsCopy = self.privateChats
        let accountsCopy = accountStore
        let auditLogCopy = auditLog
        let filesCopy = fileVault
        let configurationCopy = self.configuration
        let stringEncodingCopy = self.stringEncoding
        let connectionsCopy = self.connections

        let bannerKindCopy = configurationCopy.bannerKind
        let controlBootstrap = Self.makeControlBootstrap(
            on: eventLoopGroup,
            connections: connectionsCopy,
            sslContext: nil,
            registry: registryCopy,
            news: newsCopy,
            chatSubject: chatSubjectCopy,
            accounts: accountsCopy,
            auditLog: auditLogCopy,
            files: filesCopy,
            transfers: transfersCopy,
            privateChats: privateChatsCopy,
            configuration: configurationCopy,
            stringEncoding: stringEncodingCopy,
            bannerBytes: bannerBytes,
            bannerKind: bannerKindCopy
        )

        let transferBootstrap = Self.makeTransferBootstrap(
            on: eventLoopGroup,
            connections: connectionsCopy,
            sslContext: nil,
            transfers: transfersCopy,
            files: filesCopy
        )

        // Bind both listeners. When the user asks for port 0 (OS-pick
        // for tests), try a handful of consecutive pairs to find one
        // where (control, control+1) are both free.
        let (control, transfer) = try await Self.bindPair(
            controlBootstrap: controlBootstrap,
            transferBootstrap: transferBootstrap,
            bindHost: configuration.bindHost,
            requestedControlPort: configuration.port
        )
        self.controlChannel = control
        self.transferChannel = transfer

        let boundPort = UInt16(control.localAddress?.port ?? 0)

        // Optional TLS sibling pair (control on configuration.tlsPort,
        // HTXF on tlsPort + 1). Same per-session logic; NIOSSL is
        // prepended to the pipeline so the rest of the stack reads
        // decrypted bytes. A partially-configured TLS section (port
        // set but cert/key missing, or vice versa) fails the start so
        // operators never silently fall back to cleartext-only when
        // they thought they had TLS.
        let boundTLSPort: UInt16
        if let tlsPort = configuration.tlsPort {
            guard let certPath = configuration.tlsCertificatePath,
                  let keyPath = configuration.tlsPrivateKeyPath else {
                throw TLSContextBuilder.TLSContextError.loadFailed(
                    reason: "tls_port set but tls_certificate / tls_private_key missing"
                )
            }
            let sslContext = try TLSContextBuilder.makeContext(
                certificatePath: certPath,
                privateKeyPath: keyPath
            )
            let tlsControlBootstrap = Self.makeControlBootstrap(
                on: eventLoopGroup,
                connections: connectionsCopy,
                sslContext: sslContext,
                registry: registryCopy,
                news: newsCopy,
                chatSubject: chatSubjectCopy,
                accounts: accountsCopy,
                auditLog: auditLogCopy,
                files: filesCopy,
                transfers: transfersCopy,
                privateChats: privateChatsCopy,
                configuration: configurationCopy,
                stringEncoding: stringEncodingCopy,
                bannerBytes: bannerBytes,
                bannerKind: bannerKindCopy
            )
            let tlsTransferBootstrap = Self.makeTransferBootstrap(
                on: eventLoopGroup,
                connections: connectionsCopy,
                sslContext: sslContext,
                transfers: transfersCopy,
                files: filesCopy
            )
            let (tlsControl, tlsTransfer) = try await Self.bindPair(
                controlBootstrap: tlsControlBootstrap,
                transferBootstrap: tlsTransferBootstrap,
                bindHost: configuration.bindHost,
                requestedControlPort: tlsPort
            )
            self.tlsControlChannel = tlsControl
            self.tlsTransferChannel = tlsTransfer
            boundTLSPort = UInt16(tlsControl.localAddress?.port ?? 0)
            serverLogger.info("HeidrunServer TLS listener bound", metadata: [
                "tlsControlPort": "\(boundTLSPort)",
                "tlsTransferPort": "\(boundTLSPort + 1)"
            ])
        } else {
            boundTLSPort = 0
        }

        // Kick off the idle-away supervisor. Walks the live session
        // list on a timer and flips the `.away` flag on members who
        // haven't sent a packet in `idleAwayThreshold` seconds — the
        // standard "auto-away" behaviour from classic Hotline servers.
        // `nil` threshold disables the loop entirely.
        if let threshold = configuration.idleAwayThreshold, threshold > 0 {
            let pollSeconds = max(1, configuration.idleAwayPollInterval)
            let registrySnapshot = self.registry
            serverLogger.info("idle-away supervisor started", metadata: [
                "thresholdSeconds": "\(Int(threshold))",
                "pollSeconds": "\(Int(pollSeconds))"
            ])
            self.idleAwaySupervisor = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(pollSeconds))
                    let sessions = await registrySnapshot.liveSessions()
                    for (_, session) in sessions {
                        await session.reconcileAwayState(threshold: threshold)
                    }
                }
            }
        } else {
            serverLogger.info("idle-away supervisor disabled (threshold unset or 0)")
        }

        // Kick off tracker registration if the operator configured any.
        // The announcer captures a weak read of the registry through the
        // closure so it doesn't extend session lifetimes.
        if !configuration.trackers.isEmpty {
            let trackerHosts = configuration.trackers
                .map { "\($0.host):\($0.port)" }
                .joined(separator: ",")
            serverLogger.info("tracker configuration loaded", metadata: [
                "count": "\(configuration.trackers.count)",
                "hosts": "\(trackerHosts)"
            ])
            let registrySnapshot = self.registry
            let announceDescription = configuration.trackerDescription ?? configuration.serverName
            let announcer = TrackerAnnouncer(
                trackers: configuration.trackers,
                serverName: configuration.serverName,
                announceDescription: announceDescription,
                advertisedPort: boundPort,
                userCountProvider: {
                    let live = await registrySnapshot.snapshot()
                    return UInt16(clamping: live.count)
                },
                send: TrackerAnnouncer.makeNIOSender(group: eventLoopGroup)
            )
            self.trackerAnnouncer = announcer
            await announcer.start()
        } else {
            // No announcer instantiated → the announcer's own "skipping"
            // DEBUG log never fires. Surface the same fact here so the
            // operator can tell at INFO that HEIDRUN_TRACKERS / the TOML
            // `trackers` array reached the process empty.
            serverLogger.info("tracker announcer disabled (no trackers configured)")
        }

        return boundPort
    }

    /// Best-effort magic-byte sniff for the banner file. Returns the
    /// detected format when the bytes match a known signature, or
    /// `nil` when the format is undetectable (PICT, raw URL bytes, or
    /// an unrecognised header). Used only for the startup warning —
    /// never for routing decisions.
    private static func detectedBannerFormat(
        _ data: Data
    ) -> HeidrunCore.ServerBanner.Kind? {
        let header = data.prefix(4)
        if header.starts(with: [0xFF, 0xD8]) {
            return .jpeg
        }
        if header.starts(with: [0x47, 0x49, 0x46]) {       // "GIF"
            return .gif
        }
        if header.starts(with: [0x42, 0x4D]) {              // "BM"
            return .bmp
        }
        return nil
    }

    public func stop() async {
        serverLogger.info("HeidrunServer stopping")
        // Drain user-history departures: record a `.left` for everyone
        // still connected so a restart / redeploy doesn't strand their
        // `entered` events without a matching leave. Done first, while the
        // roster is still intact and before the channels close.
        // `recordDepartureOnce()` keeps this from double-logging against
        // each session's own disconnect cleanup as the sockets drop.
        for (_, session) in await registry.liveSessions() {
            await session.recordDepartureOnce()
        }
        idleAwaySupervisor?.cancel()
        idleAwaySupervisor = nil
        if let trackerAnnouncer {
            await trackerAnnouncer.stop()
        }
        trackerAnnouncer = nil
        try? await tlsTransferChannel?.close().get()
        try? await tlsControlChannel?.close().get()
        try? await transferChannel?.close().get()
        try? await controlChannel?.close().get()
        // Close live connections and let their per-connection session tasks
        // finish before tearing down the loops — otherwise a still-running
        // task schedules channel I/O on a dead event loop.
        await connections.drainAndWait()
        try? await group?.shutdownGracefully()
        controlChannel = nil
        transferChannel = nil
        tlsControlChannel = nil
        tlsTransferChannel = nil
        group = nil
        serverLogger.debug("HeidrunServer fully stopped")
    }

    /// Build the per-port control-channel `ServerBootstrap`. When
    /// `sslContext` is non-nil, prepends an `NIOSSLServerHandler` so
    /// the rest of the pipeline reads decrypted bytes — the per-
    /// session async task downstream is identical to the cleartext
    /// path.
    private static func makeControlBootstrap(
        on eventLoopGroup: any EventLoopGroup,
        connections: ConnectionTracker,
        sslContext: NIOSSLContext?,
        registry: UserRegistry,
        news: NewsTree,
        chatSubject: ChatSubjectStore,
        accounts: AccountStore,
        auditLog: AuditLog?,
        files: FileVault,
        transfers: TransferRegistry,
        privateChats: PrivateChatRegistry,
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding,
        bannerBytes: Data?,
        bannerKind: HeidrunCore.ServerBanner.Kind
    ) -> ServerBootstrap {
        ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                let prelude: EventLoopFuture<Void>
                let isTLS: Bool
                if let sslContext {
                    // Add via syncOperations (runs on the child channel's
                    // event loop) — NIOSSLServerHandler isn't Sendable, so the
                    // async addHandler(_:) warns under stricter NIO versions.
                    prelude = childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(
                            NIOSSLServerHandler(context: sslContext)
                        )
                    }
                    isTLS = true
                } else {
                    prelude = childChannel.eventLoop.makeSucceededVoidFuture()
                    isTLS = false
                }
                return prelude.flatMap {
                    let (inboundStream, continuation) = AsyncStream<Data>.makeStream()
                    let readerHandler = SessionIOHandler(continuation: continuation)
                    return childChannel.pipeline.addHandler(readerHandler).map {
                        let channelBox = UncheckedSendableBox(childChannel)
                        connections.add(childChannel)
                        Task {
                            await Self.runChildSession(
                                channelBox: channelBox,
                                inbound: inboundStream,
                                registry: registry,
                                news: news,
                                chatSubject: chatSubject,
                                accounts: accounts,
                                auditLog: auditLog,
                                files: files,
                                transfers: transfers,
                                privateChats: privateChats,
                                configuration: configuration,
                                stringEncoding: stringEncoding,
                                isTLS: isTLS,
                                bannerBytes: bannerBytes,
                                bannerKind: bannerKind
                            )
                            connections.remove(channelBox.value)
                        }
                    }
                }
            }
    }

    /// Build the per-port HTXF transfer-channel `ServerBootstrap`.
    /// Same TLS-prepending pattern as `makeControlBootstrap`.
    private static func makeTransferBootstrap(
        on eventLoopGroup: any EventLoopGroup,
        connections: ConnectionTracker,
        sslContext: NIOSSLContext?,
        transfers: TransferRegistry,
        files: FileVault
    ) -> ServerBootstrap {
        ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                let prelude: EventLoopFuture<Void>
                if let sslContext {
                    // syncOperations: NIOSSLServerHandler isn't Sendable (see
                    // makeControlBootstrap).
                    prelude = childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(
                            NIOSSLServerHandler(context: sslContext)
                        )
                    }
                } else {
                    prelude = childChannel.eventLoop.makeSucceededVoidFuture()
                }
                return prelude.flatMap {
                    let (inboundStream, continuation) = AsyncStream<Data>.makeStream()
                    let readerHandler = SessionIOHandler(continuation: continuation)
                    return childChannel.pipeline.addHandler(readerHandler).map {
                        let channelBox = UncheckedSendableBox(childChannel)
                        connections.add(childChannel)
                        Task {
                            await Self.runTransferChannel(
                                channelBox: channelBox,
                                inbound: inboundStream,
                                transfers: transfers,
                                files: files
                            )
                            connections.remove(channelBox.value)
                        }
                    }
                }
            }
    }

    private static func bindPair(
        controlBootstrap: ServerBootstrap,
        transferBootstrap: ServerBootstrap,
        bindHost: String,
        requestedControlPort: UInt16
    ) async throws -> (any Channel, any Channel) {
        if requestedControlPort != 0 {
            // Fixed-port mode — let the second bind throw if the
            // adjacent port is occupied. Real deployments assume
            // operators have arranged for both ports to be free.
            let control = try await controlBootstrap.bind(host: bindHost, port: Int(requestedControlPort)).get()
            do {
                let transfer = try await transferBootstrap.bind(host: bindHost, port: Int(requestedControlPort + 1)).get()
                return (control, transfer)
            } catch {
                try? await control.close().get()
                throw error
            }
        }
        // OS-pick mode — try a few times until we land a pair where
        // both ports are free. Integration tests run lots of these
        // back-to-back, so a single retry isn't enough.
        var lastError: Error?
        for _ in 0..<16 {
            do {
                let control = try await controlBootstrap.bind(host: bindHost, port: 0).get()
                let controlPort = UInt16(control.localAddress?.port ?? 0)
                do {
                    let transfer = try await transferBootstrap.bind(host: bindHost, port: Int(controlPort + 1)).get()
                    return (control, transfer)
                } catch {
                    try? await control.close().get()
                    lastError = error
                    continue
                }
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(
            domain: "HeidrunServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not find a free (control, control+1) port pair"]
        )
    }

    private static func runChildSession(
        channelBox: UncheckedSendableBox<any Channel>,
        inbound: AsyncStream<Data>,
        registry: UserRegistry,
        news: NewsTree,
        chatSubject: ChatSubjectStore,
        accounts: AccountStore,
        auditLog: AuditLog?,
        files: FileVault,
        transfers: TransferRegistry,
        privateChats: PrivateChatRegistry,
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding,
        isTLS: Bool,
        bannerBytes: Data?,
        bannerKind: HeidrunCore.ServerBanner.Kind
    ) async {
        let remoteHost: String? = {
            guard let address = channelBox.value.remoteAddress else { return nil }
            if let ip = address.ipAddress, let port = address.port {
                return "\(ip):\(port)"
            }
            return address.ipAddress ?? "\(address)"
        }()
        let remoteIP: String? = channelBox.value.remoteAddress?.ipAddress
        let session = ClientSession(
            registry: registry,
            news: news,
            chatSubject: chatSubject,
            accounts: accounts,
            files: files,
            transfers: transfers,
            privateChats: privateChats,
            configuration: configuration,
            auditLog: auditLog,
            stringEncoding: stringEncoding,
            remoteHost: remoteHost,
            remoteIP: remoteIP,
            isTLS: isTLS,
            bannerBytes: bannerBytes,
            bannerKind: bannerKind,
            writer: { packet in
                let outChannel = channelBox.value
                var buffer = outChannel.allocator.buffer(capacity: packet.count)
                buffer.writeBytes(packet)
                try await outChannel.writeAndFlush(buffer).get()
            },
            closer: {
                try? await channelBox.value.close().get()
            }
        )
        await session.run(inbound)
        try? await channelBox.value.close().get()
    }

    /// One HTXF connection. Reads the 16-byte preamble, looks up the
    /// transferID, then either streams data-fork bytes back (download)
    /// or drains the FILP/INFO/DATA/MACR envelope and commits it to
    /// the vault (upload).
    private static func runTransferChannel(
        channelBox: UncheckedSendableBox<any Channel>,
        inbound: AsyncStream<Data>,
        transfers: TransferRegistry,
        files: FileVault
    ) async {
        var stream = ByteStream(source: inbound)
        defer { Task { try? await channelBox.value.close().get() } }

        var preamble: Data
        do {
            preamble = try await stream.receiveExactly(16)
        } catch {
            return
        }
        // Magic: "HTXF" (0x48 0x54 0x58 0x46)
        guard preamble.prefix(4) == Data([0x48, 0x54, 0x58, 0x46]) else { return }
        // Bytes [12..15] are the flags slot: 0 on the legacy 16-byte
        // handshake (the `reserved` field), flagLargeFile|flagSize64 on
        // the 24-byte large-file variant. When flagSize64 is set, an
        // 8-byte UInt64 size follows that we still need to read.
        let flagBytes = preamble[preamble.startIndex + 12 ..< preamble.startIndex + 16]
        let flags = flagBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if flags & TransferHandshake.flagSize64 != 0 {
            do {
                let sizeTail = try await stream.receiveExactly(8)
                preamble.append(sizeTail)
            } catch {
                return
            }
        }
        // Parse the full (16- or 24-byte) handshake for the transferID.
        // The outer `transferSize` / 64-bit size is informational only:
        // downloads already know the byte count and the upload reader
        // sizes each fork from the FILP/INFO/DATA/MACR length fields.
        guard let parsed = TransferHandshake.parse(preamble) else { return }
        let transferID = parsed.transferID
        guard let pending = await transfers.claim(transferID: transferID) else { return }
        switch pending {
        case let .banner(bytes):
            let outChannel = channelBox.value
            let chunkSize = 16 * 1024
            var current = bytes.startIndex
            while current < bytes.endIndex {
                let end = bytes.index(current, offsetBy: chunkSize, limitedBy: bytes.endIndex) ?? bytes.endIndex
                var buffer = outChannel.allocator.buffer(capacity: chunkSize)
                buffer.writeBytes(bytes[current..<end])
                try? await outChannel.writeAndFlush(buffer).get()
                current = end
            }
            return
        case let .folderDownload(items):
            await ServerFolderDownload.drive(
                stream: &stream,
                outChannel: channelBox.value,
                items: items,
                encoding: String.Encoding.macOSRoman
            )
            return
        case let .folderUpload(path, name, itemCount):
            await ServerFolderUpload.drain(
                stream: &stream,
                outChannel: channelBox.value,
                files: files,
                path: path,
                name: name,
                itemCount: itemCount,
                encoding: String.Encoding.macOSRoman
            )
            return
        case let .download(bytes, offset):
            let outChannel = channelBox.value
            let start = min(Int(clamping: offset), bytes.count)
            let tail = bytes.suffix(from: bytes.startIndex.advanced(by: start))
            let chunkSize = 16 * 1024
            var current = tail.startIndex
            while current < tail.endIndex {
                let end = tail.index(current, offsetBy: chunkSize, limitedBy: tail.endIndex) ?? tail.endIndex
                var buffer = outChannel.allocator.buffer(capacity: chunkSize)
                buffer.writeBytes(tail[current..<end])
                try? await outChannel.writeAndFlush(buffer).get()
                current = end
            }
        case let .framedDownload(envelope):
            // Negotiated single-file download — the FILP envelope was
            // pre-assembled at the control-channel handler; stream it
            // through to the client in the same 16 KiB cadence as raw
            // downloads so a slow link sees usable progress.
            let outChannel = channelBox.value
            let chunkSize = 16 * 1024
            var current = envelope.startIndex
            while current < envelope.endIndex {
                let end = envelope.index(current, offsetBy: chunkSize, limitedBy: envelope.endIndex) ?? envelope.endIndex
                var buffer = outChannel.allocator.buffer(capacity: chunkSize)
                buffer.writeBytes(envelope[current..<end])
                try? await outChannel.writeAndFlush(buffer).get()
                current = end
            }
        case let .upload(path, name, declaredSize, resume):
            let pathDisplay = (path + [name]).joined(separator: "/")
            serverLogger.info("upload starting (HTXF)", metadata: [
                "path": "\(pathDisplay)",
                "declaredSize": "\(declaredSize)",
                "resume": "\(resume)",
                "transferID": "\(transferID)"
            ])
            // The client sometimes re-handshakes once it knows the
            // final framing size; peek for a second "HTXF" header at
            // the start of the data stream and discard it if present.
            // We don't trust its `transferSize` for read sizing — see
            // the per-fork reads below.
            //
            // Heavy INFO logging is intentional: the upload reader has
            // been the source of a non-reproducible MACR-loss bug. Each
            // milestone records `bytesReadSoFar` so a future failure
            // pinpoints exactly which read short-circuited.
            var payload = Data()
            var stage = "first-chunk"
            var innerHandshakeTransferSize: UInt32 = 0
            do {
                let firstChunk = try await stream.receiveExactly(16)
                let isInnerHandshake = firstChunk.prefix(4) == Data([0x48, 0x54, 0x58, 0x46])
                if isInnerHandshake {
                    let chunkBase = firstChunk.startIndex
                    innerHandshakeTransferSize = UInt32(firstChunk[chunkBase + 8]) << 24
                        | UInt32(firstChunk[chunkBase + 9]) << 16
                        | UInt32(firstChunk[chunkBase + 10]) << 8
                        | UInt32(firstChunk[chunkBase + 11])
                } else {
                    payload.append(firstChunk)
                }
                serverLogger.info("upload reader: first chunk", metadata: [
                    "path": "\(pathDisplay)",
                    "transferID": "\(transferID)",
                    "innerHandshake": "\(isInnerHandshake)",
                    "innerTransferSize": "\(innerHandshakeTransferSize)",
                    "bytesReadSoFar": "\(payload.count)"
                ])

                // FILP/INFO/DATA/MACR is read incrementally, with each
                // segment's length pulled from the envelope itself.
                stage = "FILP-header"
                if payload.count < 40 {
                    let head = try await stream.receiveExactly(40 - payload.count)
                    payload.append(head)
                }
                let filpBase = payload.startIndex
                let infoBlockLength = UInt32(payload[filpBase + 36]) << 24
                    | UInt32(payload[filpBase + 37]) << 16
                    | UInt32(payload[filpBase + 38]) << 8
                    | UInt32(payload[filpBase + 39])
                serverLogger.info("upload reader: FILP header complete", metadata: [
                    "transferID": "\(transferID)",
                    "infoBlockLength": "\(infoBlockLength)",
                    "bytesReadSoFar": "\(payload.count)"
                ])

                stage = "INFO-block"
                let infoBytes = try await stream.receiveExactly(Int(infoBlockLength))
                payload.append(infoBytes)
                serverLogger.info("upload reader: INFO block read", metadata: [
                    "transferID": "\(transferID)",
                    "bytesReadSoFar": "\(payload.count)"
                ])

                // Two fork bodies follow (DATA, MACR). Read each fork's
                // 16-byte header, parse its UInt32 length at bytes
                // [12..15], then pull exactly that many fork bytes.
                let forkNames = ["DATA", "MACR"]
                for forkIndex in 0..<2 {
                    stage = "\(forkNames[forkIndex])-header"
                    let forkHeader = try await stream.receiveExactly(16)
                    payload.append(forkHeader)
                    let forkBase = forkHeader.startIndex
                    let forkMagic = String(
                        data: forkHeader[forkBase..<(forkBase + 4)],
                        encoding: .ascii
                    ) ?? "????"
                    let forkLength = UInt32(forkHeader[forkBase + 12]) << 24
                        | UInt32(forkHeader[forkBase + 13]) << 16
                        | UInt32(forkHeader[forkBase + 14]) << 8
                        | UInt32(forkHeader[forkBase + 15])
                    serverLogger.info("upload reader: fork header read", metadata: [
                        "transferID": "\(transferID)",
                        "forkIndex": "\(forkIndex)",
                        "forkMagic": "\(forkMagic)",
                        "forkLength": "\(forkLength)",
                        "bytesReadSoFar": "\(payload.count)"
                    ])

                    if forkLength > 0 {
                        stage = "\(forkNames[forkIndex])-body"
                        let forkBytes = try await stream.receiveExactly(Int(forkLength))
                        payload.append(forkBytes)
                        serverLogger.info("upload reader: fork body read", metadata: [
                            "transferID": "\(transferID)",
                            "forkIndex": "\(forkIndex)",
                            "bytesReadSoFar": "\(payload.count)"
                        ])
                    }
                }
            } catch {
                serverLogger.warning("upload aborted: HTXF stream read failed", metadata: [
                    "path": "\(pathDisplay)",
                    "transferID": "\(transferID)",
                    "stage": "\(stage)",
                    "bytesReadSoFar": "\(payload.count)",
                    "innerHandshakeTransferSize": "\(innerHandshakeTransferSize)",
                    "declaredSize": "\(declaredSize)",
                    "error": "\(error)"
                ])
                return
            }
            guard let envelope = try? UploadFraming.decode(payload) else {
                serverLogger.warning("upload aborted: malformed FILP envelope", metadata: [
                    "path": "\(pathDisplay)",
                    "transferID": "\(transferID)",
                    "bytes": "\(payload.count)"
                ])
                return
            }
            let storedName = envelope.fileName.isEmpty ? name : envelope.fileName
            let wrote = await files.putFile(
                at: path,
                name: storedName,
                data: envelope.data,
                resourceFork: envelope.resourceFork,
                type: envelope.type,
                creator: envelope.creator,
                resume: resume
            )
            if wrote {
                serverLogger.info("upload complete", metadata: [
                    "path": "\(pathDisplay)",
                    "bytes": "\(envelope.data.count)",
                    "transferID": "\(transferID)"
                ])
            } else {
                // Race window: the file appeared between the control
                // channel's existence check and the HTXF receiver
                // landing bytes. FileVault.putFile refused to clobber;
                // we log so the operator notices.
                serverLogger.warning("upload failed: vault refused write (collision or invalid name)", metadata: [
                    "path": "\(pathDisplay)",
                    "bytes": "\(envelope.data.count)",
                    "transferID": "\(transferID)",
                    "resume": "\(resume)"
                ])
            }
        }
    }
}

private final class UncheckedSendableBox<Wrapped>: @unchecked Sendable {
    let value: Wrapped
    init(_ value: Wrapped) { self.value = value }
}

private final class SessionIOHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            continuation.yield(Data(bytes))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }
}
