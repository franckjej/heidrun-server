import Foundation
import HeidrunServerKit

@main
struct HeidrunServerExecutable {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment

        let port: UInt16 = {
            if let raw = environment["HEIDRUN_PORT"], let parsed = UInt16(raw) {
                return parsed
            }
            return 5500
        }()

        // Bootstrap admin on first DB init. The default credentials are
        // intentionally `admin` / `admin` so a fresh install can be
        // logged into immediately; operators are expected to change them
        // (via modifyLogin (353), `heidrun-server-admin` CLI in v1.5,
        // or whatever ops process they prefer).
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
