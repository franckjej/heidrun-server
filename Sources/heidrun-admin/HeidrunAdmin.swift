import ArgumentParser

@main
struct HeidrunAdmin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "heidrun-admin",
        abstract: "Offline administration for a heidrun-server instance.",
        subcommands: [Account.self, Audit.self, News.self, DB.self]
    )
}

// Stubs replaced in later tasks.
struct Account: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage accounts.", subcommands: []
    )
}
struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Query the audit log.")
    func run() async throws {}
}
struct News: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "News maintenance.", subcommands: []
    )
}
struct DB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Database info.")
    func run() async throws {}
}
