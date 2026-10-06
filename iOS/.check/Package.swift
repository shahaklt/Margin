// swift-tools-version: 6.0
// Type-checks the iPhone app (shared MarginKit + iOS sources) as Mac Catalyst, which uses the
// same UIKit / AVAudioSession APIs. Lets us catch iOS compile errors without full Xcode.
import PackageDescription

let package = Package(
    name: "MarginPhoneCheck",
    platforms: [.macCatalyst("26.0"), .iOS("26.0"), .macOS("26.0")],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")],
    targets: [
        .executableTarget(
            name: "MarginPhone",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            path: "Sources"
        ),
    ],
    swiftLanguageModes: [.v5]
)
