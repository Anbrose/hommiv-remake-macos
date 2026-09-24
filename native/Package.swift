// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HoMM4Native",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "H4Engine", targets: ["H4Engine"]),
        .executable(name: "h4view", targets: ["h4view"]),
    ],
    targets: [
        .target(name: "H4Engine", path: "Sources/H4Engine"),
        .executableTarget(name: "h4view", dependencies: ["H4Engine"], path: "Sources/h4view"),
        .testTarget(name: "H4EngineTests", dependencies: ["H4Engine"], path: "Tests/H4EngineTests"),
    ]
)
