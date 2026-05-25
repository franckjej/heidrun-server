import Foundation
import NIOCore
import NIOPosix
import HeidrunCore

/// Periodic UDP heartbeat that registers this server with each
/// configured tracker so it appears in directory listings third-party
/// clients fetch via the `HotlineTrackerClient` browse path.
///
/// One datagram per tracker per cycle. Cadence matches mobius's
/// `trackerUpdateFrequency = 300 s` so operators familiar with the
/// established Hotline server ecosystem don't get surprises. Per-tracker
/// errors are logged but don't kill the loop — one unreachable tracker
/// doesn't take the others down.
///
/// Network I/O is injected via the `DatagramSender` closure so the unit
/// tests don't have to open real sockets; the production wiring uses
/// `TrackerAnnouncer.makeNIOSender(group:)`.
public actor TrackerAnnouncer {
    /// Default re-registration interval. Trackers expire stale entries
    /// in the single-digit minutes; 300 s leaves headroom for a missed
    /// cycle without dropping out of listings.
    public static let updateInterval: Duration = .seconds(300)

    public typealias UserCountProvider = @Sendable () async -> UInt16
    public typealias DatagramSender = @Sendable (TrackerHost, Data) async throws -> Void

    private let trackers: [TrackerHost]
    private let serverName: String
    private let announceDescription: String
    private let advertisedPort: UInt16
    private let userCountProvider: UserCountProvider
    private let send: DatagramSender
    private let interval: Duration
    /// Stable nonce kept for the lifetime of this announcer instance.
    /// Mobius-compatible trackers key restart detection off `(sourceIP,
    /// advertisedPort, passID)`: a *changed* passID from the same
    /// endpoint signals "the server process restarted, refresh the
    /// entry." Rotating it every cycle would tell the tracker we
    /// restart every five minutes — harmless on lenient trackers, but
    /// noisy and capable of tripping anti-flap heuristics on stricter
    /// ones. We compute it once at construction and reuse.
    private let passID: UInt32

    private var runningTask: Task<Void, Never>?

    public init(
        trackers: [TrackerHost],
        serverName: String,
        announceDescription: String,
        advertisedPort: UInt16,
        userCountProvider: @escaping UserCountProvider,
        send: @escaping DatagramSender,
        interval: Duration = TrackerAnnouncer.updateInterval,
        randomPassID: @Sendable () -> UInt32 = { UInt32.random(in: 1...UInt32.max) }
    ) {
        self.trackers = trackers
        self.serverName = serverName
        self.announceDescription = announceDescription
        self.advertisedPort = advertisedPort
        self.userCountProvider = userCountProvider
        self.send = send
        self.interval = interval
        // Mint the passID exactly once. The injected `randomPassID`
        // closure is still useful for tests that want deterministic
        // bytes — they pass a constant, we call it once, the constant
        // sticks for every subsequent send.
        self.passID = randomPassID()
    }

    /// Send the first heartbeat right now, then loop on `interval`.
    /// Idempotent: cancels any prior loop before starting a new one.
    /// No-op when `trackers` is empty.
    public func start() {
        runningTask?.cancel()
        guard !trackers.isEmpty else {
            serverLogger.debug("tracker announcer: no trackers configured, skipping")
            return
        }
        serverLogger.info("tracker announcer starting", metadata: [
            "trackers": "\(trackers.count)",
            "intervalSeconds": "\(interval)"
        ])
        let cycleInterval = interval
        runningTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.announceOnce()
                do {
                    try await Task.sleep(for: cycleInterval)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        runningTask?.cancel()
        runningTask = nil
    }

    /// Build + send one packet to every tracker. Public so integration
    /// tests can drive a single cycle without spinning up the loop.
    public func announceOnce() async {
        let userCount = await userCountProvider()
        for tracker in trackers {
            let registration = TrackerRegistration(
                port: advertisedPort,
                userCount: userCount,
                passID: passID,
                name: serverName,
                description: announceDescription,
                password: tracker.password
            )
            let packet = TrackerRegistrationCodec.encode(registration)
            do {
                try await send(tracker, packet)
                serverLogger.info("tracker registered", metadata: [
                    "tracker": "\(tracker.host):\(tracker.port)",
                    "userCount": "\(userCount)",
                    "bytes": "\(packet.count)"
                ])
            } catch {
                serverLogger.warning("tracker registration failed", metadata: [
                    "tracker": "\(tracker.host):\(tracker.port)",
                    "error": "\(error)"
                ])
            }
        }
    }
}

extension TrackerAnnouncer {
    /// Production sender: open an ephemeral UDP source port, write one
    /// datagram to `(tracker.host, tracker.port)`, close. Caller still
    /// holds the `EventLoopGroup` — we don't own its lifecycle.
    ///
    /// DNS resolution uses NIO's synchronous resolver (single call per
    /// 5-min cycle, low-impact). If we ever need async DNS, swap to
    /// `NIOAsyncDNSResolver` here without touching the announcer body.
    public static func makeNIOSender(group: any EventLoopGroup) -> DatagramSender {
        { @Sendable tracker, payload in
            let channel = try await DatagramBootstrap(group: group)
                .bind(host: "0.0.0.0", port: 0)
                .get()
            do {
                let remoteAddress = try SocketAddress.makeAddressResolvingHost(
                    tracker.host,
                    port: Int(tracker.port)
                )
                var buffer = channel.allocator.buffer(capacity: payload.count)
                buffer.writeBytes(payload)
                let envelope = AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)
                try await channel.writeAndFlush(envelope).get()
            } catch {
                try? await channel.close().get()
                throw error
            }
            try? await channel.close().get()
        }
    }
}
