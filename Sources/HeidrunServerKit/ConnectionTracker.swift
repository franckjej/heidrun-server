import Foundation
import NIOCore

/// Tracks accepted connection channels so the server can close them and let
/// their per-connection session tasks run to completion **before** the
/// `EventLoopGroup` is shut down.
///
/// Each connection spawns an unstructured `Task` that writes to / closes its
/// channel. Without this drain, `stop()` would call `group.shutdownGracefully()`
/// while those tasks are still running, and their channel operations would
/// schedule on a dead event loop — NIO logs "Cannot schedule tasks on an
/// EventLoop that has already shut down" (and threatens a forced crash in
/// future versions).
///
/// Lock-guarded (not an actor) so `add`/`remove` are callable synchronously
/// from inside a NIO `childChannelInitializer`, which runs on the event loop
/// and can't `await`.
final class ConnectionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: any Channel] = [:]

    /// Register an accepted connection. Called synchronously when the channel
    /// is initialised.
    func add(_ channel: any Channel) {
        lock.lock(); defer { lock.unlock() }
        channels[ObjectIdentifier(channel)] = channel
    }

    /// Deregister a connection whose session task has finished. Called at the
    /// end of the per-connection task, both for normal disconnects and during
    /// a drain.
    func remove(_ channel: any Channel) {
        lock.lock(); defer { lock.unlock() }
        channels[ObjectIdentifier(channel)] = nil
    }

    /// Number of live connections. Test/diagnostic aid.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return channels.count
    }

    /// Whether any connection is still live.
    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return channels.isEmpty
    }

    /// Snapshot of the live channels. Kept synchronous so the lock is never
    /// held across an `await` (and `NSLock.lock()` isn't called from an async
    /// context, which Swift 6 forbids).
    private func snapshot() -> [any Channel] {
        lock.lock(); defer { lock.unlock() }
        return Array(channels.values)
    }

    /// Close every tracked channel, then wait (bounded by `timeoutMillis`)
    /// until each session task has deregistered — i.e. run to completion — so
    /// nothing is left to touch a channel after the group shuts down. Closing
    /// the channel ends the session's inbound stream, which lets the task
    /// finish; the task then calls `remove`, emptying the set.
    func drainAndWait(timeoutMillis: Int = 5000) async {
        for channel in snapshot() {
            // `Channel.close()` is thread-safe (hops to the loop, still alive
            // here since we drain before shutting the group down). Already-
            // closed channels just fail the future — ignored.
            try? await channel.close().get()
        }
        var waited = 0
        while !isEmpty, waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
    }
}
