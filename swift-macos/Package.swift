// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMChatMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LLMChatMac", targets: ["LLMChatMac"])
    ],
    targets: [
        .executableTarget(
            name: "LLMChatMac",
            path: "Sources/LLMChatMac",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LLMChatMacTests",
            dependencies: ["LLMChatMac"],
            path: "Tests/LLMChatMacTests"
        )
    ]
)
