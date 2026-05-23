import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Agreement push gate", .serialized)
struct AgreementGateTests {

    /// Drain `client.events` for `window` and return whether any
    /// `.agreementReceived` event arrived in that span.
    private static func sawAgreement(
        on client: any HotlineClient,
        within window: Duration = .milliseconds(500)
    ) async -> Bool {
        let collector = Task { () -> Bool in
            for await event in client.events {
                if case .agreementReceived = event { return true }
            }
            return false
        }
        let value: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: window)
                collector.cancel()
                return false
            }
            group.addTask { await collector.value }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return value
    }

    @Test("guest without .dontShowAgreement DOES receive the agreement push")
    func guestReceivesAgreement() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun agreement test",
            agreement: "Welcome to Heidrun. Be kind."
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            #expect(await Self.sawAgreement(on: alice) == true)
        }
    }

    @Test("admin with .dontShowAgreement does NOT receive the agreement push")
    func adminSkipsAgreement() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun agreement test",
            agreement: "Welcome to Heidrun. Be kind.",
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin",
                password: "admin",
                nickname: "Admin"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )
            #expect(await Self.sawAgreement(on: admin) == false)
        }
    }
}
