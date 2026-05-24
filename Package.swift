// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImperatorEQ",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ImperatorEQ",
            path: "Sources/ImperatorEQ"
        )
    ]
)
