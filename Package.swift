// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cockpit",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Cockpit",
            path: "Sources/Cockpit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
