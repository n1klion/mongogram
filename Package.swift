// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MongoGram",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MongoGram", targets: ["MongoGram"]),
        .library(name: "MoonKit", targets: ["MoonKit"]),
    ],
    targets: [
        .target(name: "MoonKit"),
        .executableTarget(
            name: "MongoGram",
            dependencies: ["MoonKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "MoonKitTests", dependencies: ["MoonKit"]),
    ]
)
