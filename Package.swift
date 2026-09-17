// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cockpit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Cockpit",
            path: "Sources/Cockpit"
        )
    ]
)
