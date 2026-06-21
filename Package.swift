// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeidrunServer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HeidrunServerKit", targets: ["HeidrunServerKit"]),
        .executable(name: "HeidrunServer", targets: ["HeidrunServer"])
    ],
    dependencies: [
        // Pinned with `exact:` — SemVer pre-release tags compare
        // lexically, so `from: "1.0.0-rc13"` would silently resolve back
        // to rc9 (`'1' < '9'`). Bump this in lock-step with the protocol.
        .package(url: "https://github.com/franckjej/heidrun-protocol.git", exact: "1.0.0-rc28"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "HeidrunServerKit",
            dependencies: [
                .product(name: "HeidrunCore", package: "heidrun-protocol"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "TOMLKit", package: "TOMLKit")
            ]
        ),
        .executableTarget(
            name: "HeidrunServer",
            dependencies: ["HeidrunServerKit"]
        ),
        .executableTarget(
            name: "heidrun-admin",
            dependencies: [
                "HeidrunServerKit",
                .product(name: "HeidrunCore", package: "heidrun-protocol"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "HeidrunServerKitTests",
            dependencies: [
                "HeidrunServerKit",
                .product(name: "HeidrunCore", package: "heidrun-protocol")
            ],
            resources: [
                .copy("TestCerts")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
