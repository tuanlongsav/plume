// swift-tools-version:6.0
import PackageDescription

let swift5: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]

let package = Package(
    name: "Plume",
    platforms: [
        // 13.3, not 13.0: its system WebKit (Safari 16.4) is the first that
        // sends Fetch Metadata, without which Facebook refuses the page, and
        // the first with WKWebView.isInspectable. The whole app takes its
        // floor from here (build_app.sh reads it back out of the binary).
        .macOS("13.3")
    ],
    targets: [
        .target(
            name: "PlumeCore",
            path: "Sources/PlumeCore",
            swiftSettings: swift5
        ),
        .target(
            name: "PlumeUI",
            dependencies: ["PlumeCore"],
            path: "Sources/PlumeUI",
            swiftSettings: swift5
        ),
        .target(
            name: "PlumeUpdater",
            dependencies: ["PlumeCore", "PlumeUI"],
            path: "Sources/PlumeUpdater",
            swiftSettings: swift5
        ),
        .target(
            name: "PlumeWeb",
            dependencies: ["PlumeCore", "PlumeUI"],
            path: "Sources/PlumeWeb",
            swiftSettings: swift5
        ),
        .target(
            name: "PlumeBubble",
            dependencies: ["PlumeCore", "PlumeUI"],
            path: "Sources/PlumeBubble",
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "Plume",
            dependencies: ["PlumeCore", "PlumeUI", "PlumeUpdater", "PlumeWeb", "PlumeBubble"],
            path: "Sources/Plume",
            swiftSettings: swift5
        ),
        .testTarget(
            name: "PlumeTests",
            dependencies: ["PlumeCore", "PlumeUI", "PlumeUpdater", "PlumeWeb", "PlumeBubble", "Plume"],
            path: "Tests/PlumeTests",
            swiftSettings: swift5
        ),
    ]
)
