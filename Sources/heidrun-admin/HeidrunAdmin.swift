import ArgumentParser

@main
struct HeidrunAdmin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "heidrun-admin",
        abstract: "Offline administration for a heidrun-server instance.",
        subcommands: [Account.self, Audit.self, News.self, DB.self]
    )
}
