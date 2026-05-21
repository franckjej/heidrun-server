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
    private var group: (any EventLoopGroup)?
    private var listenerChannel: (any Channel)?
    private var acceptTask: Task<Void, Never>?

    public init(
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding = .macOSRoman
    ) {
        self.configuration = configuration
        self.stringEncoding = stringEncoding
        self.registry = UserRegistry()
    }

    /// Bind the listener, spawn the accept loop, and return the bound
    /// port. Throws if the bind fails (e.g. port in use).
    public func start() async throws -> UInt16 {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = eventLoopGroup

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: Int(configuration.port))
            .get()
        self.listenerChannel = channel

        let assignedPort = UInt16(channel.localAddress?.port ?? 0)

        let registryCopy = self.registry
        let configurationCopy = self.configuration
        let stringEncodingCopy = self.stringEncoding
        self.acceptTask = Task {
            await Self.runAcceptLoop(
                channel: channel,
                registry: registryCopy,
                configuration: configurationCopy,
                stringEncoding: stringEncodingCopy
            )
        }

        return assignedPort
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        try? await listenerChannel?.close().get()
        try? await group?.shutdownGracefully()
        listenerChannel = nil
        group = nil
    }

    private static func runAcceptLoop(
        channel: any Channel,
        registry: UserRegistry,
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding
    ) async {
        let acceptedChannels = await Self.installAcceptHandler(on: channel)
        for await childChannel in acceptedChannels {
            Task {
                await Self.runChildSession(
                    channel: childChannel,
                    registry: registry,
                    configuration: configuration,
                    stringEncoding: stringEncoding
                )
            }
        }
    }

    private static func installAcceptHandler(on parent: any Channel) async -> AsyncStream<any Channel> {
        await withCheckedContinuation { continuation in
            parent.eventLoop.execute {
                let (stream, continuationHandle) = AsyncStream<any Channel>.makeStream()
                let handler = AcceptHandler(continuation: continuationHandle)
                _ = parent.pipeline.addHandler(handler)
                continuation.resume(returning: stream)
            }
        }
    }

    private static func runChildSession(
        channel: any Channel,
        registry: UserRegistry,
        configuration: ServerConfiguration,
        stringEncoding: String.Encoding
    ) async {
        let (inboundStream, inboundContinuation) = AsyncStream<Data>.makeStream()
        let readerHandler = SessionIOHandler(continuation: inboundContinuation)
        try? await channel.pipeline.addHandler(readerHandler).get()

        // NIO's Channel is thread-safe per its documentation even though it
        // isn't formally marked Sendable in the library. Wrap channel
        // references in @unchecked Sendable boxes so the Swift 6 compiler
        // accepts them across the actor/task boundary without restructuring.
        let channelBox = UncheckedSendableBox(channel)
        let session = ClientSession(
            registry: registry,
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
        await session.run(inboundStream)
        try? await channel.close().get()
    }
}

/// Thin @unchecked Sendable wrapper for values that are documented as
/// thread-safe but are not formally marked `Sendable` in their library
/// (NIO's `Channel` is the primary example here).
private final class UncheckedSendableBox<Wrapped>: @unchecked Sendable {
    let value: Wrapped
    init(_ value: Wrapped) { self.value = value }
}

/// Inbound handler installed on the parent (listener) channel. Forwards
/// each accepted child channel out into an `AsyncStream` so the accept
/// loop can iterate it with `for await`.
private final class AcceptHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = any Channel

    private let continuation: AsyncStream<any Channel>.Continuation

    init(continuation: AsyncStream<any Channel>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let child = self.unwrapInboundIn(data)
        continuation.yield(child)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }
}

/// Inbound handler installed on each child channel. Drains ByteBuffer
/// chunks into the session's inbound AsyncStream<Data>.
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
