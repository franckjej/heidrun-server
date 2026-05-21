import Foundation
import HeidrunServerKit

@main
struct HeidrunServerExecutable {
    static func main() async {
        let port: UInt16 = {
            if let raw = ProcessInfo.processInfo.environment["HEIDRUN_PORT"],
               let parsed = UInt16(raw) {
                return parsed
            }
            return 5500
        }()

        let server = HeidrunServer(configuration: ServerConfiguration(
            port: port,
            serverName: ProcessInfo.processInfo.environment["HEIDRUN_SERVER_NAME"] ?? "Heidrun"
        ))

        do {
            let bound = try await server.start()
            FileHandle.standardError.write(
                Data("HeidrunServer listening on 127.0.0.1:\(bound)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(Data("failed to bind: \(error)\n".utf8))
            exit(1)
        }

        // Block on SIGINT. The continuation must be resumed (not just
        // dropped) — Swift treats a leaked continuation as a programmer
        // error and logs "SWIFT TASK CONTINUATION MISUSE". Capturing the
        // continuation inside the signal handler lets us resume it on
        // SIGINT, drain the server, and let `main()` return cleanly.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signalSource.setEventHandler {
                signalSource.cancel()
                Task {
                    await server.stop()
                    continuation.resume()
                }
            }
            signal(SIGINT, SIG_IGN)
            signalSource.resume()
        }
    }
}
