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
        .package(url: "https://github.com/franckjej/heidrun-protocol.git", from: "1.0.0-rc5"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0")
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
