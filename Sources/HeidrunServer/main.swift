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

        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            Task {
                await server.stop()
                exit(0)
            }
        }
        signal(SIGINT, SIG_IGN)
        signalSource.resume()

        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
}
