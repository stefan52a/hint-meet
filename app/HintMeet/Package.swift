// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HintMeet",
    platforms: [.macOS(.v14)],
    targets: [
        // pure logica (telefoon-gateway): los te controleren zonder de app
        .target(
            name: "HintMeetCore",
            path: "Sources/HintMeetCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HintMeet",
            dependencies: ["HintMeetCore"],
            path: "Sources/HintMeet",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `swift run GatewayChecks`: controles op HintMeetCore. Geen XCTest/Swift Testing: met alleen de
        // Command Line Tools (geen Xcode) draait `swift test` niets.
        .executableTarget(
            name: "GatewayChecks",
            dependencies: ["HintMeetCore"],
            path: "Sources/GatewayChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
