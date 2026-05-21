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
        .package(path: "../HeidrunCore"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .target(
            name: "HeidrunServerKit",
            dependencies: [
                .product(name: "HeidrunCore", package: "HeidrunCore"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
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
                .product(name: "HeidrunCore", package: "HeidrunCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
