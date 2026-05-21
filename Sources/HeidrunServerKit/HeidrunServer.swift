import Foundation
import NIOCore
import NIOPosix
import HeidrunCore

/// Top-level server. `start()` binds a TCP listener on the configured
/// port and returns the actually-bound port (useful when callers pass
/// `port: 0` and want the OS-assigned one — integration tests do
/// exactly this). `stop()` closes the listener and shuts the event
/// loop group down gracefully.
public actor HeidrunServer {
    private let configuration: ServerConfiguration
    private let stringEncoding: String.Encoding
    private let registry: UserRegistry
    private let news: NewsTree
    private var accounts: AccountStore?
    private var group: (any EventLoopGroup)?
    private var listenerChannel: (any Channel)?

    public init(
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding = .macOSRoman
    ) {
        self.configuration = configuration
        self.stringEncoding = stringEncoding
        self.registry = UserRegistry()
        self.news = NewsTree(seed: configuration.newsSeed ?? NewsTree.Seed())
    }

    /// Bind the listener and return the bound port. The
    /// `childChannelInitializer` installs the inbound-byte handler and
    /// spawns the per-session async task **synchronously** on the
    /// child's event loop, before any reads happen — otherwise the
    /// client's 12-byte handshake races our handler installation and
    /// the session reads zero bytes forever.
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
        let accountsCopy = accountStore
        let filesCopy = fileVault
        let configurationCopy = self.configuration
        let stringEncodingCopy = self.stringEncoding

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
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
                            configuration: configurationCopy,
                            stringEncoding: stringEncodingCopy
                        )
                    }
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: Int(configuration.port)).get()
        self.listenerChannel = channel
        return UInt16(channel.localAddress?.port ?? 0)
    }

    public func stop() async {
        try? await listenerChannel?.close().get()
        try? await group?.shutdownGracefully()
        listenerChannel = nil
        group = nil
    }

    private static func runChildSession(
        channelBox: UncheckedSendableBox<any Channel>,
        inbound: AsyncStream<Data>,
        registry: UserRegistry,
        news: NewsTree,
        accounts: AccountStore,
        files: FileVault,
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding
    ) async {
        let session = ClientSession(
            registry: registry,
            news: news,
            accounts: accounts,
            files: files,
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
