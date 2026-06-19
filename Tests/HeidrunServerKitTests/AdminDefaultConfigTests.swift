import Testing
@testable import HeidrunServerKit

@Suite("AdminDefaultConfig source precedence")
struct AdminDefaultConfigTests {
    typealias Source = AdminDefaultConfig.Source

    @Test("an explicit --config / HEIDRUN_CONFIG suppresses any default")
    func explicitConfigWins() {
        let source = AdminDefaultConfig.source(
            hasExplicitConfig: true,
            hasExplicitDB: false,
            defaultConfigFile: "/etc/heidrun/heidrun-admin.toml",
            conventionDBExists: true)
        #expect(source == .none)
    }

    @Test("an explicit --db / HEIDRUN_DB_PATH suppresses any default")
    func explicitDBWins() {
        let source = AdminDefaultConfig.source(
            hasExplicitConfig: false,
            hasExplicitDB: true,
            defaultConfigFile: "./heidrun-admin.toml",
            conventionDBExists: true)
        #expect(source == .none)
    }

    @Test("with nothing explicit, a present default config file is used")
    func defaultConfigFileChosen() {
        let source = AdminDefaultConfig.source(
            hasExplicitConfig: false,
            hasExplicitDB: false,
            defaultConfigFile: "/etc/heidrun/heidrun-admin.toml",
            conventionDBExists: true)
        #expect(source == .configFile("/etc/heidrun/heidrun-admin.toml"))
    }

    @Test("with no config file, the convention DB path is used")
    func conventionDBChosen() {
        let source = AdminDefaultConfig.source(
            hasExplicitConfig: false,
            hasExplicitDB: false,
            defaultConfigFile: nil,
            conventionDBExists: true)
        #expect(source == .conventionDB(AdminDefaultConfig.conventionDBPath))
    }

    @Test("with nothing present, no default applies")
    func nothingFound() {
        let source = AdminDefaultConfig.source(
            hasExplicitConfig: false,
            hasExplicitDB: false,
            defaultConfigFile: nil,
            conventionDBExists: false)
        #expect(source == .none)
    }
}
