// swift-tools-version:6.0
import PackageDescription

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
