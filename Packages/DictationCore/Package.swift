// swift-tools-version: 6.2
import PackageDescription

// Shared, platform-neutral dictation engine: audio capture, speech-to-text,
// and text post-processing. Used by the Mac app now and the iPhone app later.
let package = Package(
    name: "DictationCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"]),
    ],
    dependencies: [
        // traits: [] = ASR + VAD only (drops TTS, diarization, NeMo text normalization).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.4", traits: []),
    ],
    targets: [
        .target(
            name: "DictationCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
