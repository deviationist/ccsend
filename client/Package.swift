// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ccsend",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ccsend",
            path: "Sources/ccsend",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
