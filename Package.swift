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
        .library(name: "ForgeLoopCli", targets: ["ForgeLoopCli"]),
        .executable(name: "forgeloop", targets: ["forgeloop"]),
        .executable(name: "ForgeLoopApp", targets: ["ForgeLoopApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/BiBoyang/ForgeLoopTUI.git", from: "1.2.0"),
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
            name: "ForgeLoopCli",
            dependencies: [
                "ForgeLoopAI",
                "ForgeLoopAgent",
                .product(name: "ForgeLoopTUI", package: "ForgeLoopTUI"),
            ],
            path: "Sources/ForgeLoopCli"
        ),
        .executableTarget(
            name: "forgeloop",
            dependencies: ["ForgeLoopCli"],
            path: "Sources/forgeloop"
        ),
        .executableTarget(
            name: "ForgeLoopApp",
            dependencies: [
                "ForgeLoopCli",
                "ForgeLoopAgent",
                "ForgeLoopAI",
                .product(name: "ForgeLoopTUI", package: "ForgeLoopTUI"),
            ],
            path: "Sources/ForgeLoopApp"
        ),
        .testTarget(
            name: "ForgeLoopAITests",
            dependencies: ["ForgeLoopAI", "ForgeLoopTestSupport"],
            path: "Tests/ForgeLoopAITests"
        ),
        .testTarget(
            name: "ForgeLoopAgentTests",
            dependencies: ["ForgeLoopAgent", "ForgeLoopAI", "ForgeLoopTestSupport"],
            path: "Tests/ForgeLoopAgentTests"
        ),
        .testTarget(
            name: "ForgeLoopCliTests",
            dependencies: [
                "ForgeLoopCli",
                "ForgeLoopAgent",
                "ForgeLoopAI",
                "ForgeLoopTestSupport",
                .product(name: "ForgeLoopTUI", package: "ForgeLoopTUI"),
            ],
            path: "Tests/ForgeLoopCliTests"
        ),
        .testTarget(
            name: "ForgeLoopTestSupport",
            dependencies: ["ForgeLoopAI", "ForgeLoopAgent"],
            path: "Tests/ForgeLoopTestSupport"
        ),
    ],
    swiftLanguageModes: [.v6]
)
