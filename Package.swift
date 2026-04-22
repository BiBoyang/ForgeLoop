// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgeLoop",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ForgeLoopAI", targets: ["ForgeLoopAI"]),
        .library(name: "ForgeLoopAgent", targets: ["ForgeLoopAgent"]),
        .library(name: "ForgeLoopTUI", targets: ["ForgeLoopTUI"]),
        .library(name: "ForgeLoopCli", targets: ["ForgeLoopCli"]),
        .executable(name: "forgeloop", targets: ["forgeloop"]),
    ],
    targets: [
        .target(
            name: "ForgeLoopAI",
            path: "Sources/ForgeLoopAI"
        ),
        .target(
            name: "ForgeLoopAgent",
            dependencies: ["ForgeLoopAI"],
            path: "Sources/ForgeLoopAgent"
        ),
        .target(
            name: "ForgeLoopTUI",
            path: "Sources/ForgeLoopTUI"
        ),
        .target(
            name: "ForgeLoopCli",
            dependencies: ["ForgeLoopAI", "ForgeLoopAgent", "ForgeLoopTUI"],
            path: "Sources/ForgeLoopCli"
        ),
        .executableTarget(
            name: "forgeloop",
            dependencies: ["ForgeLoopCli"],
            path: "Sources/forgeloop"
        ),
        .testTarget(
            name: "ForgeLoopAITests",
            dependencies: ["ForgeLoopAI"],
            path: "Tests/ForgeLoopAITests"
        ),
        .testTarget(
            name: "ForgeLoopAgentTests",
            dependencies: ["ForgeLoopAgent", "ForgeLoopAI"],
            path: "Tests/ForgeLoopAgentTests"
        ),
        .testTarget(
            name: "ForgeLoopCliTests",
            dependencies: ["ForgeLoopCli", "ForgeLoopAgent", "ForgeLoopAI", "ForgeLoopTUI"],
            path: "Tests/ForgeLoopCliTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
