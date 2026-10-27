// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shepot",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Shepot", targets: ["Shepot"])],
    targets: [
        .target(name: "WhisperCore"),
        .executableTarget(name: "Shepot", dependencies: ["WhisperCore"]),
        .testTarget(name: "WhisperCoreTests", dependencies: ["WhisperCore"]),
        .testTarget(name: "ShepotTests", dependencies: ["Shepot", "WhisperCore"])
    ]
)
