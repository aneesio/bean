// swift-tools-version:5.9
import PackageDescription

// Bean is built as a Swift Package executable and then wrapped into a proper
// .app bundle by scripts/build_app.sh. This keeps it buildable with the
// Command Line Tools alone (no full Xcode required) while still producing a
// real, signable macOS menu bar application.
let package = Package(
    name: "Bean",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Bean",
            path: "Sources/Bean"
        ),
        .testTarget(
            name: "BeanTests",
            dependencies: ["Bean"],
            path: "Tests/BeanTests"
        )
    ]
)
