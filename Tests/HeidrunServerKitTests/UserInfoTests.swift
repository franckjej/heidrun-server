import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("getClientInfoText (303)", .serialized)
struct UserInfoTests {

    @Test("renders a column-aligned profile for a logged-in user")
    func returnsProfileForKnownSocket() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(150))

            let users = try await alice.fetchUserList()
            let bobSocket = try #require(users.first(where: { $0.nickname == "Bob" })?.socket)

            let info = try await alice.fetchUserInfo(socket: bobSocket)

            #expect(info.user.nickname == "Bob")
            #expect(info.user.socket == bobSocket)
            #expect(info.infoText.contains("name: Bob"))
            #expect(info.infoText.contains("uid: \(bobSocket)"))
            #expect(info.infoText.contains("- Downloads -"))
            #expect(info.infoText.contains("- Uploads -"))
        }
    }

    @Test("authenticated session shows its account login in the profile")
    func showsAccountLogin() async throws {
        try await ServerTestHelpers.withRunningServer(
            configuration: ServerConfiguration(
                port: 0,
                bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                    login: "admin",
                    password: "admin",
                    nickname: "Admin"
                )
            )
        ) { _, port in
            let observer = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Observer")
            let admin = try await ServerTestHelpers.connectAndLogin(
                port: port,
                nickname: "Admin",
                loginName: "admin",
                password: "admin"
            )
            try await Task.sleep(for: .milliseconds(150))

            let users = try await observer.fetchUserList()
            let adminSocket = try #require(users.first(where: { $0.nickname == "Admin" })?.socket)
            let info = try await observer.fetchUserInfo(socket: adminSocket)

            #expect(info.accountLogin == "admin")
            #expect(info.infoText.contains("login: admin"))
            _ = admin
        }
    }

    @Test("unknown socket produces an error reply")
    func unknownSocketIsAnError() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            try await Task.sleep(for: .milliseconds(100))

            await #expect(throws: (any Error).self) {
                _ = try await alice.fetchUserInfo(socket: 9999)
            }
        }
    }
}
