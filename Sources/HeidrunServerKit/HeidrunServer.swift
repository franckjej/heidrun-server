import Foundation
import NIOCore
import NIOPosix
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
    private var accounts: AccountStore?
    private var group: (any EventLoopGroup)?
    private var controlChannel: (any Channel)?
    private var transferChannel: (any Channel)?

    public init(
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding = .macOSRoman
    ) {
        self.configuration = configuration
        self.stringEncoding = stringEncoding
        self.registry = UserRegistry()
        self.news = NewsTree(seed: configuration.newsSeed ?? NewsTree.Seed())
        self.transfers = TransferRegistry()
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
        let fileVault = try FileVault(rootPath: configuration.filesRootPath)
        if let bootstrap = configuration.bootstrapAdmin {
            _ = try await accountStore.bootstrapIfEmpty(
                login: bootstrap.login,
                password: bootstrap.password,
                nickname: bootstrap.nickname,
                permissions: AccountPrivilege.disconnectUsers.rawValue
                    | AccountPrivilege.createAccounts.rawValue
                    | AccountPrivilege.deleteAccounts.rawValue
                    | AccountPrivilege.readAccounts.rawValue
                    | AccountPrivilege.modifyAccounts.rawValue
            )
        }
        self.accounts = accountStore

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = eventLoopGroup

        let registryCopy = self.registry
        let newsCopy = self.news
        let transfersCopy = self.transfers
        let accountsCopy = accountStore
        let filesCopy = fileVault
        let configurationCopy = self.configuration
        let stringEncodingCopy = self.stringEncoding

        let controlBootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                let (inboundStream, continuation) = AsyncStream<Data>.makeStream()
                let readerHandler = SessionIOHandler(continuation: continuation)
                return childChannel.pipeline.addHandler(readerHandler).map {
                    let channelBox = UncheckedSendableBox(childChannel)
                    Task {
                        await Self.runChildSession(
                            channelBox: channelBox,
                            inbound: inboundStream,
                            registry: registryCopy,
                            news: newsCopy,
                            accounts: accountsCopy,
                            files: filesCopy,
                            transfers: transfersCopy,
                            configuration: configurationCopy,
                            stringEncoding: stringEncodingCopy
                        )
                    }
                }
            }

        let transferBootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                let (inboundStream, continuation) = AsyncStream<Data>.makeStream()
                let readerHandler = SessionIOHandler(continuation: continuation)
                return childChannel.pipeline.addHandler(readerHandler).map {
                    let channelBox = UncheckedSendableBox(childChannel)
                    Task {
                        await Self.runTransferChannel(
                            channelBox: channelBox,
                            inbound: inboundStream,
                            transfers: transfersCopy,
                            files: filesCopy
                        )
                    }
                }
            }

        // Bind both listeners. When the user asks for port 0 (OS-pick
        // for tests), try a handful of consecutive pairs to find one
        // where (control, control+1) are both free.
        let (control, transfer) = try await Self.bindPair(
            controlBootstrap: controlBootstrap,
            transferBootstrap: transferBootstrap,
            requestedControlPort: configuration.port
        )
        self.controlChannel = control
        self.transferChannel = transfer
        return UInt16(control.localAddress?.port ?? 0)
    }

    public func stop() async {
        serverLogger.info("HeidrunServer stopping")
        try? await transferChannel?.close().get()
        try? await controlChannel?.close().get()
        try? await group?.shutdownGracefully()
        controlChannel = nil
        transferChannel = nil
        group = nil
        serverLogger.debug("HeidrunServer fully stopped")
    }

    private static func bindPair(
        controlBootstrap: ServerBootstrap,
        transferBootstrap: ServerBootstrap,
        requestedControlPort: UInt16
    ) async throws -> (any Channel, any Channel) {
        if requestedControlPort != 0 {
            // Fixed-port mode — let the second bind throw if the
            // adjacent port is occupied. Real deployments assume
            // operators have arranged for both ports to be free.
            let control = try await controlBootstrap.bind(host: "127.0.0.1", port: Int(requestedControlPort)).get()
            do {
                let transfer = try await transferBootstrap.bind(host: "127.0.0.1", port: Int(requestedControlPort + 1)).get()
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
                let control = try await controlBootstrap.bind(host: "127.0.0.1", port: 0).get()
                let controlPort = UInt16(control.localAddress?.port ?? 0)
                do {
                    let transfer = try await transferBootstrap.bind(host: "127.0.0.1", port: Int(controlPort + 1)).get()
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
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding
    ) async {
        let session = ClientSession(
            registry: registry,
            news: news,
            accounts: accounts,
            files: files,
            transfers: transfers,
            configuration: configuration,
            stringEncoding: stringEncoding,
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
            _ = await files.putFile(at: path, name: storedName, data: envelope.data, resume: resume)
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
