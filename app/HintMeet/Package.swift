// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HintMeet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HintMeet",
            path: "Sources/HintMeet",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
