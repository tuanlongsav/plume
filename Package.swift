// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Plume",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Plume",
            path: "Sources/Plume",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PlumeTests",
            dependencies: ["Plume"],
            path: "Tests/PlumeTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
