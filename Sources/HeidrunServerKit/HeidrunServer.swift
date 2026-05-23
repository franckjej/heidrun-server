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
        let accountStore = try AccountStore(
            path: configuration.accountStorePath,
            passwordRounds: configuration.passwordRounds
        )
        // File metadata persistence rides along the same SQLite file
        // as the accounts DB when one is configured; otherwise it's
        // in-memory and wipes alongside the account store.
        let fileMetadataStore = try FileMetadataStore(path: configuration.accountStorePath)
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
        let transfersCopy = self.transfers
        let privateChatsCopy = self.privateChats
        let accountsCopy = accountStore
        let filesCopy = fileVault
        let configurationCopy = self.configuration
        let stringEncodingCopy = self.stringEncoding

        let bannerKindCopy = configurationCopy.bannerKind
        let controlBootstrap = Self.makeControlBootstrap(
            on: eventLoopGroup,
            sslContext: nil,
            registry: registryCopy,
            news: newsCopy,
            accounts: accountsCopy,
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
                sslContext: sslContext,
                registry: registryCopy,
                news: newsCopy,
                accounts: accountsCopy,
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
                tlsPort: boundTLSPort,
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
        sslContext: NIOSSLContext?,
        registry: UserRegistry,
        news: NewsTree,
        accounts: AccountStore,
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
                    prelude = childChannel.pipeline.addHandler(
                        NIOSSLServerHandler(context: sslContext)
                    )
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
                        Task {
                            await Self.runChildSession(
                                channelBox: channelBox,
                                inbound: inboundStream,
                                registry: registry,
                                news: news,
                                accounts: accounts,
                                files: files,
                                transfers: transfers,
                                privateChats: privateChats,
                                configuration: configuration,
                                stringEncoding: stringEncoding,
                                isTLS: isTLS,
                                bannerBytes: bannerBytes,
                                bannerKind: bannerKind
                            )
                        }
                    }
                }
            }
    }

    /// Build the per-port HTXF transfer-channel `ServerBootstrap`.
    /// Same TLS-prepending pattern as `makeControlBootstrap`.
    private static func makeTransferBootstrap(
        on eventLoopGroup: any EventLoopGroup,
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
                    prelude = childChannel.pipeline.addHandler(
                        NIOSSLServerHandler(context: sslContext)
                    )
                } else {
                    prelude = childChannel.eventLoop.makeSucceededVoidFuture()
                }
                return prelude.flatMap {
                    let (inboundStream, continuation) = AsyncStream<Data>.makeStream()
                    let readerHandler = SessionIOHandler(continuation: continuation)
                    return childChannel.pipeline.addHandler(readerHandler).map {
                        let channelBox = UncheckedSendableBox(childChannel)
                        Task {
                            await Self.runTransferChannel(
                                channelBox: channelBox,
                                inbound: inboundStream,
                                transfers: transfers,
                                files: files
                            )
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
        accounts: AccountStore,
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
        let session = ClientSession(
            registry: registry,
            news: news,
            accounts: accounts,
            files: files,
            transfers: transfers,
            privateChats: privateChats,
            configuration: configuration,
            stringEncoding: stringEncoding,
            remoteHost: remoteHost,
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

        let preamble: Data
        do {
            preamble = try await stream.receiveExactly(16)
        } catch {
            return
        }
        // Magic: "HTXF" (0x48 0x54 0x58 0x46)
        guard preamble.prefix(4) == Data([0x48, 0x54, 0x58, 0x46]) else { return }
        let base = preamble.startIndex
        let transferID = UInt32(preamble[base + 4]) << 24
            | UInt32(preamble[base + 5]) << 16
            | UInt32(preamble[base + 6]) << 8
            | UInt32(preamble[base + 7])
        let preambleSize = UInt32(preamble[base + 8]) << 24
            | UInt32(preamble[base + 9]) << 16
            | UInt32(preamble[base + 10]) << 8
            | UInt32(preamble[base + 11])
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
            let start = min(Int(offset), bytes.count)
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
        case let .upload(path, name, declaredSize, resume):
            // The client sometimes re-handshakes once it knows the
            // final framing size; peek for a second "HTXF" header at
            // the start of the data stream. (Matches the test
            // server's drainUpload in HeidrunTestServer/Sources/
            // HeidrunTestServerKit/TransferListener.swift.)
            let total: UInt32
            var payload = Data()
            do {
                let firstChunk = try await stream.receiveExactly(16)
                if firstChunk.prefix(4) == Data([0x48, 0x54, 0x58, 0x46]) {
                    let chunkBase = firstChunk.startIndex
                    total = UInt32(firstChunk[chunkBase + 8]) << 24
                        | UInt32(firstChunk[chunkBase + 9]) << 16
                        | UInt32(firstChunk[chunkBase + 10]) << 8
                        | UInt32(firstChunk[chunkBase + 11])
                } else {
                    payload.append(firstChunk)
                    total = preambleSize == 0 ? declaredSize : preambleSize
                }
                let remaining = Int(total) - payload.count
                if remaining > 0 {
                    let rest = try await stream.receiveExactly(remaining)
                    payload.append(rest)
                }
            } catch {
                return
            }
            guard let envelope = try? UploadFraming.decode(payload) else { return }
            let storedName = envelope.fileName.isEmpty ? name : envelope.fileName
            _ = await files.putFile(
                at: path,
                name: storedName,
                data: envelope.data,
                type: envelope.type,
                creator: envelope.creator,
                resume: resume
            )
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
