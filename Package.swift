// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "ImperatorEQ",
    // macOS 14.2 is the first release with Core Audio process taps
    // (AudioHardwareCreateProcessTap), which is how the app captures what the
    // Mac plays. The SDK stamp that decides which generation of AppKit controls
    // gets drawn is applied by build.sh through -Xlinker -platform_version.
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "ImperatorEQ",
            path: "Sources/ImperatorEQ",
            // swift-tools-version 6.4 turns on Swift 6 language mode, which this
            // pre-concurrency code does not compile under. That migration is a
            // separate job from the SDK stamp.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
