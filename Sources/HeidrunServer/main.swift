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

        // Resolve config: HEIDRUN_CONFIG points at a TOML file, env
        // vars layer on top. Without HEIDRUN_CONFIG the file shape
        // collapses to "everything defaulted" and env vars are the
        // sole source — same behaviour as before M4.
        let configFile: ServerConfigurationFile
        if let configPath = environment["HEIDRUN_CONFIG"] {
            do {
                configFile = try ServerConfigurationFile.load(from: configPath)
                serverLogger.info("loaded config", metadata: ["path": "\(configPath)"])
            } catch {
                serverLogger.critical("failed to load HEIDRUN_CONFIG", metadata: [
                    "path": "\(configPath)",
                    "error": "\(error)"
                ])
                exit(1)
            }
        } else {
            configFile = ServerConfigurationFile()
        }
        let configuration = configFile.resolved(environment: environment)

        let server = HeidrunServer(configuration: configuration)

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
