import Foundation
import Logging
import HeidrunServerKit

@main
struct HeidrunServerExecutable {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment

        // Bootstrap swift-log before anything else logs. Default level
        // is `info` for production; override with HEIDRUN_LOG_LEVEL
        // (case-insensitive: trace, debug, info, notice, warning, error,
        // critical).
        let logLevel = environment["HEIDRUN_LOG_LEVEL"]
            .flatMap { Logger.Level(rawValue: $0.lowercased()) }
            ?? .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = logLevel
            return handler
        }

        let port: UInt16 = {
            if let raw = environment["HEIDRUN_PORT"], let parsed = UInt16(raw) {
                return parsed
            }
            return 5500
        }()

        // Bootstrap admin on first DB init. The default credentials are
        // intentionally `admin` / `admin` so a fresh install can be
        // logged into immediately; operators are expected to change them
        // via modifyLogin (353) or whatever ops process they prefer.
        let bootstrap = ServerConfiguration.BootstrapAdmin(
            login: environment["HEIDRUN_ADMIN_LOGIN"] ?? "admin",
            password: environment["HEIDRUN_ADMIN_PASSWORD"] ?? "admin",
            nickname: environment["HEIDRUN_ADMIN_NICKNAME"] ?? "Admin"
        )

        let server = HeidrunServer(configuration: ServerConfiguration(
            port: port,
            serverName: environment["HEIDRUN_SERVER_NAME"] ?? "Heidrun",
            accountStorePath: environment["HEIDRUN_DB_PATH"],
            bootstrapAdmin: bootstrap,
            filesRootPath: environment["HEIDRUN_FILES_ROOT"]
        ))

        do {
            let bound = try await server.start()
            serverLogger.info("HeidrunServer listening", metadata: [
                "controlPort": "\(bound)",
                "transferPort": "\(bound + 1)"
            ])
        } catch {
            serverLogger.critical("failed to bind", metadata: [
                "error": "\(error)"
            ])
            exit(1)
        }

        // Block on SIGINT or SIGTERM. The continuation must be resumed
        // (not just dropped) — Swift treats a leaked continuation as a
        // programmer error and logs "SWIFT TASK CONTINUATION MISUSE".
        // Capturing the continuation in both signal handlers lets us
        // resume it on shutdown, drain the server, and let main() return
        // cleanly so the process exits 0.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            let resumeOnce = ContinuationGuard(continuation: continuation)
            for source in [sigint, sigterm] {
                let signalName = source === sigint ? "SIGINT" : "SIGTERM"
                source.setEventHandler {
                    sigint.cancel()
                    sigterm.cancel()
                    serverLogger.info("shutdown signal received, draining", metadata: [
                        "signal": "\(signalName)"
                    ])
                    Task {
                        await server.stop()
                        serverLogger.info("server stopped cleanly")
                        resumeOnce.resume()
                    }
                }
            }
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            sigint.resume()
            sigterm.resume()
        }
    }
}

/// Resume-once guard. Both signal handlers may fire (SIGINT then
/// SIGTERM, or vice versa) during shutdown; we only want to resume the
/// continuation on the first signal.
private final class ContinuationGuard: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard let pending = continuation else { return }
        continuation = nil
        pending.resume()
    }
}
