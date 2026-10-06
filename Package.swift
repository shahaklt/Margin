// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Margin",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/Margin"
        ),
    ],
    swiftLanguageModes: [.v5]
)
