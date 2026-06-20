import Foundation
import Logging
import HeidrunServerKit

@main
enum HeidrunServerExecutable {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment

        // Default level is `info`; override with HEIDRUN_LOG_LEVEL
        // (case-insensitive: trace, debug, info, notice, warning, error,
        // critical).
        let logLevel = environment["HEIDRUN_LOG_LEVEL"]
            .flatMap { Logger.Level(rawValue: $0.lowercased()) }
            ?? .info

        // Resolve config BEFORE bootstrapping logging: the operational-log
        // file sink path comes from the resolved configuration. Until
        // bootstrap runs, swift-log's default handler writes to stderr, so
        // the early config-load failure below is still visible.
        let configFile: ServerConfigurationFile
        if let configPath = environment["HEIDRUN_CONFIG"] {
            do {
                configFile = try ServerConfigurationFile.load(from: configPath)
            } catch {
                FileHandle.standardError.write(Data(
                    "critical: failed to load HEIDRUN_CONFIG \(configPath): \(error)\n".utf8))
                exit(1)
            }
        } else {
            configFile = ServerConfigurationFile()
        }
        let configuration = configFile.resolved(environment: environment)

        // Operational-log file sink (in addition to stderr) when enabled and a
        // path resolved. `docker logs` output is unchanged either way.
        let operationalLogWriter: NDJSONLogWriter? = {
            guard configuration.operationalLogEnabled,
                  let path = configuration.operationalLogPath else { return nil }
            return NDJSONLogWriter(
                path: path,
                maxBytes: configuration.operationalLogMaxBytes,
                keep: configuration.operationalLogKeep)
        }()
        LoggingSystem.bootstrap { label in
            OperationalLogging.handler(label: label, level: logLevel, writer: operationalLogWriter)
        }
        if let configPath = environment["HEIDRUN_CONFIG"] {
            serverLogger.info("loaded config", metadata: ["path": "\(configPath)"])
        }
        if let path = configuration.operationalLogPath, operationalLogWriter != nil {
            serverLogger.info("operational log file", metadata: ["path": "\(path)"])
        }

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
            for (signalName, source) in [("SIGINT", sigint), ("SIGTERM", sigterm)] {
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
