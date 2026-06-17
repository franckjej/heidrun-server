import ArgumentParser
import HeidrunCore
import HeidrunServerKit

struct Account: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage accounts.",
        subcommands: [Create.self, List.self, Show.self, Passwd.self,
                      Rename.self, Privileges.self, Delete.self]
    )

    struct Create: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Login (unique).") var login: String
        @Option(help: "Display nickname (defaults to the login).") var name: String?
        @Option(help: "Password (avoid in shared shells; prefer --password-stdin).")
        var password: String?
        @Flag(help: "Read the password from stdin.") var passwordStdin = false
        @Option(help: "Comma-separated privilege names to grant.") var grant: String?
        @Option(help: "Preset permission set: guest or admin.") var preset: String?

        func run() async throws {
            let store = try global.openAccountStore()
            let secret = try resolvePassword(
                explicit: password, fromStdin: passwordStdin, prompt: "New password: ")
            var permissions: UInt64 = 0
            if let preset {
                switch preset.lowercased() {
                case "guest": permissions = HeidrunServerKit.Account.guestDefaultPermissions
                case "admin": permissions = UserPrivileges.all.rawValue
                default: throw ValidationError("Unknown preset '\(preset)' (use guest or admin).")
                }
            }
            if let grant {
                let parsed = PrivilegeNames.parse(grant)
                if !parsed.unknown.isEmpty {
                    throw ValidationError("Unknown privileges: \(parsed.unknown.joined(separator: ", "))")
                }
                permissions |= parsed.matched.rawValue
            }
            let account = try await AdminCommands.create(
                store: store, login: login, password: secret,
                nickname: name, permissions: permissions)
            print("Created account '\(account.login)'.")
        }
    }

    struct List: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Flag(help: "Emit JSON.") var json = false
        func run() async throws {
            let accounts = try await AdminCommands.list(store: global.openAccountStore())
            if json {
                print(try AdminFormat.json(accounts.map(AdminFormat.accountDTO)))
            } else {
                print(AdminFormat.accountTable(accounts))
            }
        }
    }

    struct Show: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var login: String
        @Flag(help: "Emit JSON.") var json = false
        func run() async throws {
            let account = try await AdminCommands.show(store: global.openAccountStore(), login: login)
            if json {
                print(try AdminFormat.json(AdminFormat.accountDTO(account)))
            } else {
                print(AdminFormat.accountDetail(account))
            }
        }
    }

    struct Passwd: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var login: String
        @Flag(help: "Read the new password from stdin.") var passwordStdin = false
        func run() async throws {
            let secret = try resolvePassword(
                explicit: nil, fromStdin: passwordStdin, prompt: "New password: ")
            _ = try await AdminCommands.setPassword(
                store: global.openAccountStore(), login: login, newPassword: secret)
            print("Password updated for '\(login)'.")
        }
    }

    struct Rename: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var login: String
        @Option(help: "New display nickname.") var name: String
        func run() async throws {
            _ = try await AdminCommands.rename(
                store: global.openAccountStore(), login: login, nickname: name)
            print("Renamed '\(login)' to '\(name)'.")
        }
    }

    struct Privileges: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var login: String
        @Option(help: "Comma-separated names to grant.") var grant: String?
        @Option(help: "Comma-separated names to revoke.") var revoke: String?
        @Option(help: "Comma-separated names to set as the entire mask.") var set: String?
        @Flag(name: .long, help: "List all privilege names with on/off state.") var list = false

        func run() async throws {
            let store = try global.openAccountStore()
            if list {
                let account = try await AdminCommands.show(store: store, login: login)
                let held = Set(PrivilegeNames.names(in: UserPrivileges(rawValue: account.permissions)))
                for name in PrivilegeNames.allNames {
                    print("\(held.contains(name) ? "[x]" : "[ ]") \(name)")
                }
                return
            }
            let grantBits = try parsePrivileges(grant)
            let revokeBits = try parsePrivileges(revoke)
            let setBits = set == nil ? nil : try parsePrivileges(set)
            let updated = try await AdminCommands.editPrivileges(
                store: store, login: login,
                grant: grantBits, revoke: revokeBits, set: setBits)
            let names = PrivilegeNames.names(in: UserPrivileges(rawValue: updated.permissions))
            print("Privileges for '\(login)': " + (names.isEmpty ? "(none)" : names.joined(separator: ", ")))
        }

        private func parsePrivileges(_ csv: String?) throws -> UserPrivileges {
            guard let csv else { return [] }
            let parsed = PrivilegeNames.parse(csv)
            if !parsed.unknown.isEmpty {
                throw ValidationError("Unknown privileges: \(parsed.unknown.joined(separator: ", "))")
            }
            return parsed.matched
        }
    }

    struct Delete: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var login: String
        @Flag(name: .long, help: "Skip the confirmation prompt.") var yes = false
        func run() async throws {
            let proceed = ConfirmationGate.shouldProceed(assumeYes: yes) {
                AdminIO.confirm("Delete account '\(login)'?")
            }
            guard proceed else { print("Aborted."); return }
            let removed = try await AdminCommands.delete(store: global.openAccountStore(), login: login)
            print(removed ? "Deleted '\(login)'." : "No account '\(login)'.")
        }
    }
}

/// Resolve a password from --password, --password-stdin, or an interactive
/// no-echo prompt, in that order.
func resolvePassword(explicit: String?, fromStdin: Bool, prompt: String) throws -> String {
    if let explicit {
        if explicit.isEmpty { throw ValidationError("Empty password.") }
        return explicit
    }
    let value = fromStdin ? AdminIO.readPasswordFromStdin() : AdminIO.readPassword(prompt: prompt)
    if value.isEmpty { throw ValidationError("Empty password.") }
    return value
}
