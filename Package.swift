// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cotype",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CotypeCore", targets: ["CotypeCore"]),
        .library(name: "CotypeUpdateCore", targets: ["CotypeUpdateCore"]),
        .library(name: "CotypeEval", targets: ["CotypeEval"]),
        .library(name: "CotypeMacOS", targets: ["CotypeMacOS"]),
        .executable(name: "cotype", targets: ["CotypeApp"]),
        .executable(name: "cotype-eval", targets: ["CotypeEvalApp"]),
        .executable(name: "cotype-menu", targets: ["CotypeMenuApp"]),
        .executable(name: "cotype-diagnostics", targets: ["CotypeDiagnostics"]),
        .executable(name: "cotype-update", targets: ["CotypeUpdate"]),
    ],
    dependencies: [
        // Sparkle 2: the mature, community-maintained auto-update framework (an
        // independent open-source project — not Apple-supported). The app links
        // the SPM binary framework, drives it through SPUStandardUpdater
        // Controller (Check for Updates + automatic checks), and embeds + signs
        // the framework (and its bundled Updater.app / XPC services) in the
        // release bundle. See docs/RELEASE.md.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/tristan-mcinnis/design-system", from: "1.0.0"),
    ],
    targets: [
        .target(name: "CotypeUpdateCore"),
        .target(name: "CotypeCore", dependencies: ["llama"]),
        .target(name: "CotypeEval", dependencies: ["CotypeCore"]),
        .target(name: "CotypeMacOS", dependencies: ["CotypeCore", .product(name: "HouseDesign", package: "design-system")]),
        .executableTarget(name: "CotypeUpdate", dependencies: ["CotypeUpdateCore"]),
        .executableTarget(name: "CotypeApp", dependencies: ["CotypeCore"]),
        .executableTarget(name: "CotypeEvalApp", dependencies: ["CotypeEval", "CotypeMacOS"]),
        .executableTarget(name: "CotypeMenuApp", dependencies: [
            "CotypeCore",
            "CotypeMacOS",
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "HouseDesign", package: "design-system"),
            .product(name: "HouseUIKit", package: "design-system"),
        ]),
        .executableTarget(name: "CotypeDiagnostics", dependencies: ["CotypeCore"]),
        .testTarget(name: "CotypeCoreTests", dependencies: ["CotypeCore"]),
        .testTarget(name: "CotypeUpdateCoreTests", dependencies: ["CotypeUpdateCore"]),
        .testTarget(name: "CotypeEvalTests", dependencies: ["CotypeEval"]),
        .testTarget(name: "CotypeMacOSTests", dependencies: ["CotypeMacOS", "CotypeCore"]),
        // The menu app's own window rules: the menu bar a normal window gets,
        // and when the app goes back to being a menu-bar app.
        .testTarget(name: "CotypeMenuAppTests", dependencies: [
            "CotypeMenuApp",
            .product(name: "HouseDesign", package: "design-system"),
            .product(name: "HouseUIKit", package: "design-system"),
        ]),
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10665/llama-b10665-xcframework.zip",
            checksum: "44cd51d0f61cd966f5f9ec3d89a9198ec730291a11f098406f7284811d4c4201"
        ),
    ]
)
