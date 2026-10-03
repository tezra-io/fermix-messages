// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "fermix-messages",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fermix-messages", targets: ["fermix-messages"]),
        .library(name: "FermixMessagesCore", targets: ["FermixMessagesCore"]),
    ],
    targets: [
        .target(
            name: "FermixMessagesCore",
            path: "Sources/FermixMessagesCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "fermix-messages",
            dependencies: ["FermixMessagesCore"],
            path: "Sources/fermix-messages"
        ),
        .testTarget(
            name: "FermixMessagesCoreTests",
            dependencies: ["FermixMessagesCore"],
            path: "Tests/FermixMessagesCoreTests"
        ),
    ]
)
