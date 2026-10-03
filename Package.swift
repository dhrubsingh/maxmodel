// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hearth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hearth", targets: ["Hearth"]),
        .executable(name: "hearth-smoke", targets: ["HearthSmoke"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "HearthCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")], resources: [.copy("catalog.json"), .copy("model-notices"), .copy("discovery-examples.json"), .copy("recommendation-evidence.json")]),
        // The packaged app embeds Sparkle.framework in Contents/Frameworks.
        .executableTarget(name: "Hearth", dependencies: ["HearthCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "HearthSmoke", dependencies: ["HearthCore"]),
        .testTarget(name: "HearthCoreTests", dependencies: ["HearthCore"]),
        .testTarget(name: "HearthAppTests", dependencies: ["Hearth", "HearthCore"]),
    ],
    swiftLanguageModes: [.v5]
)
